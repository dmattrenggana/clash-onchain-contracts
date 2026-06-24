// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ClashCards.sol";
import "../src/ClashCardManager.sol";
import "./ClashCards.t.sol";  // imports MockERC20

/**
 * @title Security tests - EIP-712, cost validation, replay, expiration
 * @notice Verifies the security model:
 *   - User CANNOT mint without paying correct $CLASH
 *   - User CANNOT bypass via replay
 *   - User CANNOT bypass via expired signature
 *   - User CANNOT submit operation for another user
 *   - User CANNOT forge server signature (EIP-712 + AccessControl)
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

    // EIP-712 typehashes (must match ClashCardManager)
    bytes32 constant UPGRADE_TYPEHASH = keccak256(
        "UpgradeRequest(address user,uint256 cardType,uint256 fromLevel,uint256 toLevel,uint256 tokenIdBurn,uint256 tokenIdMint,uint256 burnAmount,uint256 clashCost,uint256 nonce,uint256 deadline)"
    );

    bytes32 constant PACK_TYPEHASH = keccak256(
        "PackRequest(address user,bytes32 packId,uint256 clashCost,uint256 nonce,uint256 deadline)"
    );

    bytes32 constant CHEST_TYPEHASH = keccak256(
        "ChestRequest(address user,uint8 chestType,uint256 clashCost,uint256 nonce,uint256 deadline)"
    );

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

        token.mint(user1, 1_000_000_000 ether);
        token.mint(user2, 1_000_000_000 ether);
        token.mint(attacker, 1_000_000_000 ether);
        vm.prank(user1); token.approve(address(manager), type(uint256).max);
        vm.prank(user2); token.approve(address(manager), type(uint256).max);
        vm.prank(attacker); token.approve(address(manager), type(uint256).max);
    }

    // ========== EIP-712 signing helper ==========

    function _signUpgrade(ClashCardManager.UpgradeRequest memory req) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(
            UPGRADE_TYPEHASH,
            req.user,
            req.cardType,
            req.fromLevel,
            req.toLevel,
            req.tokenIdBurn,
            req.tokenIdMint,
            req.burnAmount,
            req.clashCost,
            req.nonce,
            req.deadline
        ));
        bytes32 digest = manager.digestHash(structHash);  // EIP-712 + domain
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(GAME_SERVER_PK, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signPack(ClashCardManager.PackRequest memory req) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(
            PACK_TYPEHASH,
            req.user,
            req.packId,
            req.clashCost,
            req.nonce,
            req.deadline
        ));
        bytes32 digest = manager.digestHash(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(GAME_SERVER_PK, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signChest(ClashCardManager.ChestRequest memory req) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(
            CHEST_TYPEHASH,
            req.user,
            req.chestType,
            req.clashCost,
            req.nonce,
            req.deadline
        ));
        bytes32 digest = manager.digestHash(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(GAME_SERVER_PK, digest);
        return abi.encodePacked(r, s, v);
    }

    // ========== Cost validation tests ==========

    function testUpgradeCostMismatchReverts() public {
        ClashCardManager.UpgradeRequest memory req = ClashCardManager.UpgradeRequest({
            user: user1,
            cardType: 0,
            fromLevel: 1,
            toLevel: 2,
            tokenIdBurn: 0,
            tokenIdMint: 1,
            burnAmount: 10,
            clashCost: 1 ether,  // WRONG
            nonce: 1,
            deadline: block.timestamp + 1000
        });

        bytes memory sig = _signUpgrade(req);

        vm.expectRevert(
            abi.encodeWithSelector(
                ClashCardManager.CostMismatch.selector,
                10_000_000 ether, 1 ether
            )
        );
        vm.prank(user1);
        manager.upgradeCard(req, sig);
    }

    function testUpgradeCorrectCostWorks() public {
        uint256 correctCost = 10_000_000 ether;
        ClashCardManager.UpgradeRequest memory req = ClashCardManager.UpgradeRequest({
            user: user1,
            cardType: 0,
            fromLevel: 1,
            toLevel: 2,
            tokenIdBurn: 0,
            tokenIdMint: 1,
            burnAmount: 10,
            clashCost: correctCost,
            nonce: 2,
            deadline: block.timestamp + 1000
        });

        bytes memory sig = _signUpgrade(req);

        cards.mint(user1, 0, 10, "");
        vm.prank(user1);
        cards.setApprovalForAll(address(manager), true);

        uint256 balBefore = token.balanceOf(treasury);
        uint256 user1NftBefore = cards.balanceOf(user1, 0);

        vm.prank(user1);
        manager.upgradeCard(req, sig);

        assertEq(token.balanceOf(treasury) - balBefore, correctCost);
        assertEq(cards.balanceOf(user1, 0), user1NftBefore - 10);
        assertEq(cards.balanceOf(user1, 1), 1);
    }

    // ========== Replay protection ==========

    function testReplayReverts() public {
        uint256 correctCost = 10_000_000 ether;
        ClashCardManager.UpgradeRequest memory req = ClashCardManager.UpgradeRequest({
            user: user1,
            cardType: 0,
            fromLevel: 1,
            toLevel: 2,
            tokenIdBurn: 0,
            tokenIdMint: 1,
            burnAmount: 10,
            clashCost: correctCost,
            nonce: 3,
            deadline: block.timestamp + 1000
        });

        bytes memory sig = _signUpgrade(req);

        cards.mint(user1, 0, 10, "");
        vm.prank(user1);
        cards.setApprovalForAll(address(manager), true);

        vm.prank(user1);
        manager.upgradeCard(req, sig);

        bytes32 opId = keccak256(abi.encode(req));
        vm.expectRevert(
            abi.encodeWithSelector(ClashCardManager.AlreadyProcessed.selector, opId)
        );
        vm.prank(user1);
        manager.upgradeCard(req, sig);
    }

    // ========== Expiration ==========

    function testExpiredReverts() public {
        ClashCardManager.UpgradeRequest memory req = ClashCardManager.UpgradeRequest({
            user: user1,
            cardType: 0,
            fromLevel: 1,
            toLevel: 2,
            tokenIdBurn: 0,
            tokenIdMint: 1,
            burnAmount: 10,
            clashCost: 10_000_000 ether,
            nonce: 4,
            deadline: block.timestamp - 1
        });

        bytes memory sig = _signUpgrade(req);

        vm.expectRevert();  // Expired error
        vm.prank(user1);
        manager.upgradeCard(req, sig);
    }

    // ========== Wrong user ==========

    function testWrongUserReverts() public {
        ClashCardManager.UpgradeRequest memory req = ClashCardManager.UpgradeRequest({
            user: user1,
            cardType: 0,
            fromLevel: 1,
            toLevel: 2,
            tokenIdBurn: 0,
            tokenIdMint: 1,
            burnAmount: 10,
            clashCost: 10_000_000 ether,
            nonce: 5,
            deadline: block.timestamp + 1000
        });

        bytes memory sig = _signUpgrade(req);

        vm.expectRevert(
            abi.encodeWithSelector(
                ClashCardManager.WrongUser.selector, user1, user2
            )
        );
        vm.prank(user2);
        manager.upgradeCard(req, sig);
    }

    // ========== Invalid signature ==========

    function testInvalidSignatureReverts() public {
        ClashCardManager.UpgradeRequest memory req = ClashCardManager.UpgradeRequest({
            user: user1,
            cardType: 0,
            fromLevel: 1,
            toLevel: 2,
            tokenIdBurn: 0,
            tokenIdMint: 1,
            burnAmount: 10,
            clashCost: 10_000_000 ether,
            nonce: 6,
            deadline: block.timestamp + 1000
        });

        // Sign with attacker key instead of game server
        bytes32 structHash = keccak256(abi.encode(
            UPGRADE_TYPEHASH,
            req.user,
            req.cardType,
            req.fromLevel,
            req.toLevel,
            req.tokenIdBurn,
            req.tokenIdMint,
            req.burnAmount,
            req.clashCost,
            req.nonce,
            req.deadline
        ));
        bytes32 digest = manager.digestHash(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xBEEF, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.expectRevert();  // InvalidSignature
        vm.prank(user1);
        manager.upgradeCard(req, sig);
    }

    // ========== Direct mint attempts ==========

    function testDirectMintReverts() public {
        vm.expectRevert();
        vm.prank(attacker);
        cards.mint(attacker, 0, 1000, "");
    }

    function testDirectMintBatchReverts() public {
        uint256[] memory tokenIds = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);
        tokenIds[0] = 0; amounts[0] = 100;
        tokenIds[1] = 1; amounts[1] = 100;

        vm.expectRevert();
        vm.prank(attacker);
        cards.mintBatch(attacker, tokenIds, amounts, "");
    }

    // ========== Burn count validation ==========

    function testBurnCountMismatchReverts() public {
        ClashCardManager.UpgradeRequest memory req = ClashCardManager.UpgradeRequest({
            user: user1,
            cardType: 0,
            fromLevel: 1,
            toLevel: 2,
            tokenIdBurn: 0,
            tokenIdMint: 1,
            burnAmount: 5,  // WRONG! Should be 10
            clashCost: 10_000_000 ether,
            nonce: 100,
            deadline: block.timestamp + 1000
        });

        bytes memory sig = _signUpgrade(req);

        vm.expectRevert(
            abi.encodeWithSelector(ClashCardManager.InvalidBurnCount.selector)
        );
        vm.prank(user1);
        manager.upgradeCard(req, sig);
    }

    // ========== Token ID validation ==========

    function testInvalidMintTokenIdReverts() public {
        // Try to upgrade Knight L1 -> L2 but claim to mint tokenId 30 (Wyvern L1)
        ClashCardManager.UpgradeRequest memory req = ClashCardManager.UpgradeRequest({
            user: user1,
            cardType: 0,
            fromLevel: 1,
            toLevel: 2,
            tokenIdBurn: 0,
            tokenIdMint: 30,  // WRONG! Should be 1
            burnAmount: 10,
            clashCost: 10_000_000 ether,
            nonce: 101,
            deadline: block.timestamp + 1000
        });

        bytes memory sig = _signUpgrade(req);

        vm.expectRevert(
            abi.encodeWithSelector(
                ClashCardManager.InvalidMintTokenId.selector, 1, 30
            )
        );
        vm.prank(user1);
        manager.upgradeCard(req, sig);
    }

    // ========== Buy pack ==========

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

        bytes memory sig = _signPack(req);

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
            clashCost: 100_000 ether,  // WRONG
            nonce: 8,
            deadline: block.timestamp + 1000
        });

        bytes memory sig = _signPack(req);

        vm.expectRevert(
            abi.encodeWithSelector(
                ClashCardManager.CostMismatch.selector, 200_000 ether, 100_000 ether
            )
        );
        vm.prank(user1);
        manager.buyPack(req, sig, tokenIds, amounts);
    }

    // ========== Buy chest ==========

    function testBuyChestCorrectCost() public {
        uint256[] memory tokenIds = new uint256[](20);
        uint256[] memory amounts = new uint256[](20);
        for (uint256 i = 0; i < 20; i++) {
            tokenIds[i] = i % 10;
            amounts[i] = 1;
        }

        ClashCardManager.ChestRequest memory req = ClashCardManager.ChestRequest({
            user: user1,
            chestType: ClashCardManager.ChestType.Silver,
            clashCost: 1_000_000 ether,
            nonce: 9,
            deadline: block.timestamp + 1000
        });

        bytes memory sig = _signChest(req);

        uint256 balBefore = token.balanceOf(treasury);

        vm.prank(user1);
        manager.buyChest(req, sig, tokenIds, amounts);

        assertEq(token.balanceOf(treasury) - balBefore, 1_000_000 ether);
    }

    // ========== View functions ==========

    function testGetUpgradeBurnCount() public view {
        assertEq(manager.getUpgradeBurnCount(1), 10);
        assertEq(manager.getUpgradeBurnCount(2), 40);
        assertEq(manager.getUpgradeBurnCount(3), 80);
        assertEq(manager.getUpgradeBurnCount(9), 5120);
    }

    function testSetUpgradeBurnCount() public {
        manager.setUpgradeBurnCount(1, 20);
        assertEq(manager.getUpgradeBurnCount(1), 20);
    }

    // ========== Flexibility tests ==========

    function testAddCardType() public {
        // Initial: 12 card types (0-11)
        assertEq(manager.getCardTypeCount(), 12);
        assertTrue(manager.cardTypeExists(0));
        assertTrue(manager.cardTypeExists(11));
        assertFalse(manager.cardTypeExists(12));

        // Add 13th card type
        manager.addCardType(12);
        assertTrue(manager.cardTypeExists(12));
        assertEq(manager.getCardTypeCount(), 13);
    }

    function testAddCardTypeDuplicateReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(ClashCardManager.CardTypeAlreadyExists.selector, 0)
        );
        manager.addCardType(0);  // Knight already exists
    }

    function testAddCardTypeExceedsMaxReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(ClashCardManager.ExceedsMaxCardTypes.selector)
        );
        manager.addCardType(256);  // >= MAX_CARD_TYPES
    }

    function testRemoveCardType() public {
        assertTrue(manager.cardTypeExists(5));
        manager.removeCardType(5);
        assertFalse(manager.cardTypeExists(5));
    }

    function testRemoveNonExistentCardTypeReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(ClashCardManager.CardTypeDoesNotExist.selector, 12)
        );
        manager.removeCardType(12);  // Never added
    }

    function testSetMaxLevel() public {
        // Initial maxLevel = 10
        assertEq(manager.maxLevel(), 10);
        assertEq(manager.getUpgradeCost(9), 2_560_000_000 ether);

        // Increase to 15
        manager.setMaxLevel(15);
        assertEq(manager.maxLevel(), 15);

        // New levels should have 2x default pricing
        assertEq(manager.getUpgradeCost(10), 5_120_000_000 ether);   // 2x L9->L10
        assertEq(manager.getUpgradeCost(14), 81_920_000_000 ether);  // 2x L13->L14

        assertEq(manager.getUpgradeBurnCount(10), 10240);
        assertEq(manager.getUpgradeBurnCount(14), 163840);
    }

    function testSetMaxLevelDecreaseReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ClashCardManager.CannotDecreaseMaxLevel.selector, 10, 5
            )
        );
        manager.setMaxLevel(5);
    }

    function testSetMaxLevelExceedsMaxReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(ClashCardManager.ExceedsMaxLevels.selector)
        );
        manager.setMaxLevel(257);  // > MAX_LEVELS_PER_TYPE (256)
    }

    function testNewCardTypeWithNewLevel() public {
        // Add 13th card type and extend max level to 15
        manager.addCardType(12);
        manager.setMaxLevel(15);

        // Verify token ID encoding works for new types/levels
        // cardType 12, level 1 = 12*256 + 0 = 3072
        assertEq(manager.tokenIdOf(12, 1), 3072);
        // cardType 12, level 15 = 12*256 + 14 = 3086
        assertEq(manager.tokenIdOf(12, 15), 3086);
        // cardType 0 (Knight), level 15 = 0*256 + 14 = 14
        assertEq(manager.tokenIdOf(0, 15), 14);
    }
}
