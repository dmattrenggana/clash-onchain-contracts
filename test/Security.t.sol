// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ClashCards.sol";
import "../src/ClashCardManager.sol";
import "./ClashCards.t.sol";  // imports MockERC20

/**
 * @title Security tests - cost validation, replay, expiration
 * @notice Verifies the security model:
 *   - User CANNOT mint without paying correct $CLASH
 *   - User CANNOT bypass via replay
 *   - User CANNOT bypass via expired signature
 *   - User CANNOT submit operation for another user
 */
contract SecurityTest is Test {
    ClashCards public cards;
    ClashCardManager public manager;
    MockERC20 public token;
    address public admin = address(this);
    address public treasury = address(0x2);
    address public royaltyReceiver = address(0x3);
    uint256 constant GAME_SERVER_PK = 0xA11CE;
    address public gameServer = vm.addr(GAME_SERVER_PK);
    address public user1 = address(0x5);
    address public user2 = address(0x6);
    address public attacker = address(0x7);

    string public constant BASE_URI = "https://example.com/metadata/";

    function setUp() public {
        token = new MockERC20("Clash", "CLASH");
        cards = new ClashCards(BASE_URI, royaltyReceiver, admin);
        manager = new ClashCardManager(
            address(token),
            address(cards),
            treasury,
            admin
        );
        cards.grantRole(cards.MINTER_ROLE(), address(manager));
        cards.grantRole(cards.BURNER_ROLE(), address(manager));
        manager.grantRole(manager.GAME_SERVER_ROLE(), gameServer);

        // Setup user1
        token.mint(user1, 1_000_000_000 ether);
        vm.prank(user1);
        token.approve(address(manager), type(uint256).max);

        // Setup user2
        token.mint(user2, 1_000_000_000 ether);
        vm.prank(user2);
        token.approve(address(manager), type(uint256).max);

        // Setup attacker
        token.mint(attacker, 1_000_000_000 ether);
        vm.prank(attacker);
        token.approve(address(manager), type(uint256).max);
    }

    // ========== Cost validation tests ==========

    function testUpgradeCostMismatchReverts() public {
        // Sign upgrade with WRONG cost
        ClashCardManager.UpgradeRequest memory req = ClashCardManager.UpgradeRequest({
            user: user1,
            cardType: ClashCardManager.CardType.Knight,
            fromLevel: 1,
            toLevel: 2,
            tokenIdBurn: 0,
            tokenIdMint: 1,
            burnAmount: 10,
            clashCost: 1 ether,  // WRONG! Should be 10_000_000 ether
            nonce: 1,
            deadline: block.timestamp + 1000
        });

        bytes32 opId = keccak256(abi.encode(req));
        bytes memory sig = signOperation(gameServer, opId);

        vm.expectRevert("Cost mismatch");
        vm.prank(user1);
        manager.upgradeCard(req, sig);
    }

    function testUpgradeCorrectCostWorks() public {
        // Sign upgrade with CORRECT cost
        uint256 correctCost = 10_000_000 ether;
        ClashCardManager.UpgradeRequest memory req = ClashCardManager.UpgradeRequest({
            user: user1,
            cardType: ClashCardManager.CardType.Knight,
            fromLevel: 1,
            toLevel: 2,
            tokenIdBurn: 0,
            tokenIdMint: 1,
            burnAmount: 10,
            clashCost: correctCost,
            nonce: 2,
            deadline: block.timestamp + 1000
        });

        bytes32 opId = keccak256(abi.encode(req));
        bytes memory sig = signOperation(gameServer, opId);

        // Mint 10 Knight L1 to user1
        cards.mint(user1, 0, 10, "");
        vm.prank(user1);
        cards.setApprovalForAll(address(manager), true);

        uint256 balBefore = token.balanceOf(treasury);
        uint256 user1NftBefore = cards.balanceOf(user1, 0);

        vm.prank(user1);
        manager.upgradeCard(req, sig);

        // Verify $CLASH paid
        assertEq(token.balanceOf(treasury) - balBefore, correctCost);
        // Verify NFT burned
        assertEq(cards.balanceOf(user1, 0), user1NftBefore - 10);
        // Verify NFT minted
        assertEq(cards.balanceOf(user1, 1), 1);
    }

    // ========== Replay protection tests ==========

    function testReplayReverts() public {
        // First, get the operation to succeed
        uint256 correctCost = 10_000_000 ether;
        ClashCardManager.UpgradeRequest memory req = ClashCardManager.UpgradeRequest({
            user: user1,
            cardType: ClashCardManager.CardType.Knight,
            fromLevel: 1,
            toLevel: 2,
            tokenIdBurn: 0,
            tokenIdMint: 1,
            burnAmount: 10,
            clashCost: correctCost,
            nonce: 3,
            deadline: block.timestamp + 1000
        });

        bytes32 opId = keccak256(abi.encode(req));
        bytes memory sig = signOperation(gameServer, opId);

        cards.mint(user1, 0, 10, "");
        vm.prank(user1);
        cards.setApprovalForAll(address(manager), true);

        // First call succeeds
        vm.prank(user1);
        manager.upgradeCard(req, sig);

        // Replay should revert
        vm.expectRevert("Already processed");
        vm.prank(user1);
        manager.upgradeCard(req, sig);
    }

    // ========== Expiration tests ==========

    function testExpiredReverts() public {
        ClashCardManager.UpgradeRequest memory req = ClashCardManager.UpgradeRequest({
            user: user1,
            cardType: ClashCardManager.CardType.Knight,
            fromLevel: 1,
            toLevel: 2,
            tokenIdBurn: 0,
            tokenIdMint: 1,
            burnAmount: 10,
            clashCost: 10_000_000 ether,
            nonce: 4,
            deadline: block.timestamp - 1  // EXPIRED
        });

        bytes32 opId = keccak256(abi.encode(req));
        bytes memory sig = signOperation(gameServer, opId);

        vm.expectRevert("Expired");
        vm.prank(user1);
        manager.upgradeCard(req, sig);
    }

    // ========== Wrong user tests ==========

    function testWrongUserReverts() public {
        ClashCardManager.UpgradeRequest memory req = ClashCardManager.UpgradeRequest({
            user: user1,  // signed for user1
            cardType: ClashCardManager.CardType.Knight,
            fromLevel: 1,
            toLevel: 2,
            tokenIdBurn: 0,
            tokenIdMint: 1,
            burnAmount: 10,
            clashCost: 10_000_000 ether,
            nonce: 5,
            deadline: block.timestamp + 1000
        });

        bytes32 opId = keccak256(abi.encode(req));
        bytes memory sig = signOperation(gameServer, opId);

        // user2 tries to submit user1's signed operation
        vm.expectRevert("Wrong user");
        vm.prank(user2);
        manager.upgradeCard(req, sig);
    }

    // ========== Invalid signature tests ==========

    function testInvalidSignatureReverts() public {
        ClashCardManager.UpgradeRequest memory req = ClashCardManager.UpgradeRequest({
            user: user1,
            cardType: ClashCardManager.CardType.Knight,
            fromLevel: 1,
            toLevel: 2,
            tokenIdBurn: 0,
            tokenIdMint: 1,
            burnAmount: 10,
            clashCost: 10_000_000 ether,
            nonce: 6,
            deadline: block.timestamp + 1000
        });

        bytes32 opId = keccak256(abi.encode(req));
        // Sign with WRONG private key (attacker, not game server)
        uint256 attackerPk = 0xBEEF;
        bytes32 ethSignedMessageHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", opId)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attackerPk, ethSignedMessageHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.expectRevert("Invalid signature");
        vm.prank(user1);
        manager.upgradeCard(req, sig);
    }

    // ========== Direct mint attempt tests ==========

    function testDirectMintReverts() public {
        // Attacker tries to mint directly on ClashCards
        vm.expectRevert();
        vm.prank(attacker);
        cards.mint(attacker, 0, 1000, "");
    }

    function testDirectMintBatchReverts() public {
        uint256[] memory tokenIds = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);
        tokenIds[0] = 0;
        tokenIds[1] = 1;
        amounts[0] = 100;
        amounts[1] = 100;

        vm.expectRevert();
        vm.prank(attacker);
        cards.mintBatch(attacker, tokenIds, amounts, "");
    }

    function testBurnCountMismatchReverts() public {
        // Try to upgrade with WRONG burn count (5 instead of 10 for L1->L2)
        ClashCardManager.UpgradeRequest memory req = ClashCardManager.UpgradeRequest({
            user: user1,
            cardType: ClashCardManager.CardType.Knight,
            fromLevel: 1,
            toLevel: 2,
            tokenIdBurn: 0,
            tokenIdMint: 1,
            burnAmount: 5,  // WRONG! Should be 10
            clashCost: 10_000_000 ether,
            nonce: 100,
            deadline: block.timestamp + 1000
        });

        bytes32 opId = keccak256(abi.encode(req));
        bytes memory sig = signOperation(gameServer, opId);

        vm.expectRevert("Burn count mismatch");
        vm.prank(user1);
        manager.upgradeCard(req, sig);
    }

    function testGetUpgradeBurnCount() public view {
        // Verify burn count getter returns correct values
        assertEq(manager.getUpgradeBurnCount(1), 10);
        assertEq(manager.getUpgradeBurnCount(2), 40);
        assertEq(manager.getUpgradeBurnCount(3), 80);
        assertEq(manager.getUpgradeBurnCount(9), 5120);
    }

    function testSetUpgradeBurnCount() public {
        manager.setUpgradeBurnCount(1, 20);
        assertEq(manager.getUpgradeBurnCount(1), 20);
    }

    // ========== Buy pack tests ==========

    function testBuyPackCorrectCost() public {
        bytes32 packId = keccak256("FIVE_PACK");
        manager.setPackCost(packId, 200_000 ether);

        uint256[] memory tokenIds = new uint256[](5);
        uint256[] memory amounts = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            tokenIds[i] = i;
            amounts[i] = 1;
        }

        ClashCardManager.PackRequest memory req = ClashCardManager.PackRequest({
            user: user1,
            packId: packId,
            clashCost: 200_000 ether,
            nonce: 7,
            deadline: block.timestamp + 1000
        });

        bytes32 opId = keccak256(abi.encode(req, tokenIds, amounts));
        bytes memory sig = signOperation(gameServer, opId);

        uint256 balBefore = token.balanceOf(treasury);

        vm.prank(user1);
        manager.buyPack(req, sig, tokenIds, amounts);

        assertEq(token.balanceOf(treasury) - balBefore, 200_000 ether);
        for (uint256 i = 0; i < 5; i++) {
            assertEq(cards.balanceOf(user1, i), 1);
        }
    }

    function testBuyPackCostMismatchReverts() public {
        bytes32 packId = keccak256("FIVE_PACK");
        manager.setPackCost(packId, 200_000 ether);

        uint256[] memory tokenIds = new uint256[](5);
        uint256[] memory amounts = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            tokenIds[i] = i;
            amounts[i] = 1;
        }

        ClashCardManager.PackRequest memory req = ClashCardManager.PackRequest({
            user: user1,
            packId: packId,
            clashCost: 100_000 ether,  // WRONG! Should be 200_000
            nonce: 8,
            deadline: block.timestamp + 1000
        });

        bytes32 opId = keccak256(abi.encode(req, tokenIds, amounts));
        bytes memory sig = signOperation(gameServer, opId);

        vm.expectRevert("Cost mismatch");
        vm.prank(user1);
        manager.buyPack(req, sig, tokenIds, amounts);
    }

    // ========== Buy chest tests ==========

    function testBuyChestCorrectCost() public {
        uint256[] memory tokenIds = new uint256[](20);
        uint256[] memory amounts = new uint256[](20);
        for (uint256 i = 0; i < 20; i++) {
            tokenIds[i] = i % 10;  // mix of levels
            amounts[i] = 1;
        }

        ClashCardManager.ChestRequest memory req = ClashCardManager.ChestRequest({
            user: user1,
            chestType: ClashCardManager.ChestType.Silver,
            clashCost: 1_000_000 ether,
            nonce: 9,
            deadline: block.timestamp + 1000
        });

        bytes32 opId = keccak256(abi.encode(req, tokenIds, amounts));
        bytes memory sig = signOperation(gameServer, opId);

        uint256 balBefore = token.balanceOf(treasury);

        vm.prank(user1);
        manager.buyChest(req, sig, tokenIds, amounts);

        assertEq(token.balanceOf(treasury) - balBefore, 1_000_000 ether);
    }

    // ========== Helper: sign operation ==========

    function signOperation(address signer, bytes32 opId) internal pure returns (bytes memory) {
        bytes32 ethSignedMessageHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", opId)
        );
        // Use gameServer private key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(GAME_SERVER_PK, ethSignedMessageHash);
        return abi.encodePacked(r, s, v);
    }
}
