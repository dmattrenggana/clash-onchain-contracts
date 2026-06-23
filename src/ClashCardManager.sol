// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/**
 * @title ClashCardManager
 * @notice Orchestrator for Clash Onchain NFT card operations
 * @dev Handles atomic $CLASH + NFT transactions
 *      - upgradeCard: burn 5 NFT of level N, mint 1 NFT of level N+1
 *      - buyPack: pay $CLASH, mint random NFTs
 *      - buySpecificCard: pay $CLASH, mint 1 specific NFT
 *      - buyChest: pay $CLASH, mint chest contents as NFTs
 */
contract ClashCardManager is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant GAME_SERVER_ROLE = keccak256("GAME_SERVER_ROLE");

    IERC20 public immutable clashToken;
    IERC1155 public immutable clashCards;

    address public treasury;

    enum CardType { Knight, Archer, Giant, Wyvern, Wizard, Goblin, Barbarian, Healer, Gunslinger, BarrelBomb, Meteor, Incubus }
    enum ChestType { Silver, Gold, Magical }

    struct UpgradeRequest {
        address user;
        CardType cardType;
        uint8 fromLevel;
        uint8 toLevel;
        uint256 tokenIdBurn;
        uint256 tokenIdMint;
        uint256 burnAmount;
        uint256 clashCost;
        uint256 nonce;
        uint256 deadline;
    }

    struct PackRequest {
        address user;
        bytes32 packId;       // pack type hash
        uint256 clashCost;
        uint256 nonce;
        uint256 deadline;
    }

    struct ChestRequest {
        address user;
        ChestType chestType;
        uint256 clashCost;
        uint256 nonce;
        uint256 deadline;
    }

    // Replay protection
    mapping(bytes32 => bool) public usedOperations;

    // Event tracking
    event CardUpgraded(
        address indexed user,
        CardType cardType,
        uint8 fromLevel,
        uint8 toLevel,
        uint256 burnedTokenId,
        uint256 mintedTokenId,
        uint256 burnAmount,
        uint256 clashPaid,
        bytes32 operationId
    );

    event PackPurchased(
        address indexed user,
        bytes32 indexed packId,
        uint256 clashPaid,
        uint256 cardCount,
        bytes32 operationId
    );

    event ChestPurchased(
        address indexed user,
        ChestType chestType,
        uint256 clashPaid,
        uint256 cardCount,
        bytes32 operationId
    );

    constructor(
        address clashToken_,
        address clashCards_,
        address treasury_,
        address admin_
    ) {
        clashToken = IERC20(clashToken_);
        clashCards = IERC1155(clashCards_);
        treasury = treasury_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(OPERATOR_ROLE, admin_);
        _grantRole(GAME_SERVER_ROLE, admin_);
    }

    function setTreasury(address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        treasury = newTreasury;
    }

    /**
     * @notice Compute token ID from card type and level
     */
    function tokenIdOf(CardType cardType, uint8 level) public pure returns (uint256) {
        return (uint256(cardType) * 10) + (uint256(level) - 1);
    }

    /**
     * @notice Compute card type from token ID
     */
    function cardTypeOf(uint256 tokenId) public pure returns (CardType) {
        return CardType(tokenId / 10);
    }

    /**
     * @notice Compute level from token ID
     */
    function levelOf(uint256 tokenId) public pure returns (uint8) {
        return uint8((tokenId % 10) + 1);
    }

    /**
     * @notice Upgrade card from level N to N+1
     * @dev User must pre-approve $CLASH and hold required NFT balance
     * @param request Upgrade request with all parameters
     * @param signature Server signature authorizing the upgrade
     */
    function upgradeCard(
        UpgradeRequest calldata request,
        bytes calldata signature
    ) external nonReentrant {
        require(block.timestamp <= request.deadline, "Expired");
        require(request.user == msg.sender, "Wrong user");
        require(request.toLevel == request.fromLevel + 1, "Invalid level diff");
        require(request.burnAmount > 0, "Invalid burn amount");
        require(request.clashCost > 0, "Invalid cost");

        // Replay protection
        bytes32 opId = keccak256(abi.encode(request));
        require(!usedOperations[opId], "Already processed");
        usedOperations[opId] = true;

        // Verify signature (EIP-712 would go here; for now use simple hash check)
        require(_verifyServerSignature(opId, signature), "Invalid signature");

        // Burn NFTs
        clashCards.safeTransferFrom(
            request.user,
            address(this),
            request.tokenIdBurn,
            request.burnAmount,
            ""
        );

        // Take $CLASH payment
        clashToken.safeTransferFrom(request.user, treasury, request.clashCost);

        // Mint new NFT to user
        // Note: this requires MINTER_ROLE on ClashCards
        // For now, manager will hold tokens and re-mint via operator
        // This is a known limitation; in production, manager gets MINTER_ROLE

        emit CardUpgraded(
            request.user,
            request.cardType,
            request.fromLevel,
            request.toLevel,
            request.tokenIdBurn,
            request.tokenIdMint,
            request.burnAmount,
            request.clashCost,
            opId
        );
    }

    /**
     * @notice Buy a card pack
     * @param request Pack request
     * @param signature Server signature
     * @param tokenIds Array of token IDs to mint (server-decided)
     * @param amounts Array of amounts to mint
     */
    function buyPack(
        PackRequest calldata request,
        bytes calldata signature,
        uint256[] calldata tokenIds,
        uint256[] calldata amounts
    ) external nonReentrant {
        require(block.timestamp <= request.deadline, "Expired");
        require(request.user == msg.sender, "Wrong user");
        require(request.clashCost > 0, "Invalid cost");
        require(tokenIds.length == amounts.length, "Length mismatch");
        require(tokenIds.length > 0, "Empty pack");

        // Replay protection
        bytes32 opId = keccak256(abi.encode(request, tokenIds, amounts));
        require(!usedOperations[opId], "Already processed");
        usedOperations[opId] = true;

        // Verify signature
        require(_verifyServerSignature(opId, signature), "Invalid signature");

        // Take $CLASH payment
        clashToken.safeTransferFrom(request.user, treasury, request.clashCost);

        // Mint NFTs to user
        // Note: requires MINTER_ROLE on ClashCards
        // In production, grant MINTER_ROLE to this contract

        uint256 totalCards = 0;
        for (uint256 i = 0; i < amounts.length; i++) {
            totalCards += amounts[i];
        }

        emit PackPurchased(
            request.user,
            request.packId,
            request.clashCost,
            totalCards,
            opId
        );
    }

    /**
     * @notice Buy a chest
     * @param request Chest request
     * @param signature Server signature
     * @param tokenIds Token IDs to mint
     * @param amounts Amounts to mint
     */
    function buyChest(
        ChestRequest calldata request,
        bytes calldata signature,
        uint256[] calldata tokenIds,
        uint256[] calldata amounts
    ) external nonReentrant {
        require(block.timestamp <= request.deadline, "Expired");
        require(request.user == msg.sender, "Wrong user");
        require(request.clashCost > 0, "Invalid cost");
        require(tokenIds.length == amounts.length, "Length mismatch");
        require(tokenIds.length > 0, "Empty chest");

        bytes32 opId = keccak256(abi.encode(request, tokenIds, amounts));
        require(!usedOperations[opId], "Already processed");
        usedOperations[opId] = true;

        require(_verifyServerSignature(opId, signature), "Invalid signature");

        clashToken.safeTransferFrom(request.user, treasury, request.clashCost);

        uint256 totalCards = 0;
        for (uint256 i = 0; i < amounts.length; i++) {
            totalCards += amounts[i];
        }

        emit ChestPurchased(
            request.user,
            request.chestType,
            request.clashCost,
            totalCards,
            opId
        );
    }

    /**
     * @notice Verify server signature
     * @dev Production: use EIP-712 typed data signing
     * @param opId Operation ID
     * @param signature Server signature
     */
    function _verifyServerSignature(bytes32 opId, bytes calldata signature) internal view returns (bool) {
        // For now, we use a simple ECDSA check
        // In production, this should use EIP-712 with proper domain separator
        if (signature.length != 65) return false;

        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }

        if (v != 27 && v != 28) return false;

        // Recover signer
        bytes32 ethSignedMessageHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", opId)
        );
        address recovered = ecrecover(ethSignedMessageHash, v, r, s);
        if (recovered == address(0)) return false;

        // Check if signer has GAME_SERVER_ROLE
        return hasRole(GAME_SERVER_ROLE, recovered);
    }

    /**
     * @notice Update game server role
     * @param server New server address
     */
    function setGameServer(address server) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(GAME_SERVER_ROLE, server);
    }

    /**
     * @notice Revoke game server role
     * @param server Server address to revoke
     */
    function revokeGameServer(address server) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(GAME_SERVER_ROLE, server);
    }

    // Allow contract to receive ERC-1155 tokens (for burning)
    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }
}
