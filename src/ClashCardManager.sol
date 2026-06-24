// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "./ClashCards.sol";

/**
 * @title  ClashCardManager
 * @notice Orchestrator for Clash Onchain card operations.
 * @dev    Atomic $CLASH + NFT transactions:
 *          - upgradeCard:  burn 5+ NFTs of level N → mint 1 NFT of level N+1
 *          - buyPack:      pay $CLASH → mint batch of random NFTs (deferred)
 *          - buyChest:     pay $CLASH → mint batch of NFT chest contents
 *
 *          Flexibility (admin-only):
 *          - addCardType(cardTypeId): register new card type (up to 256)
 *          - setMaxLevel(newMaxLevel): increase max level (up to 256)
 *
 *          Token ID encoding (stable, supports up to 256 card types × 256 levels):
 *          - tokenId = (cardTypeId × MAX_LEVELS_PER_TYPE) + (level - 1)
 *          - Initial state: 12 card types (0-11) × 10 levels = 120 tokens
 *          - New card types: 12, 13, ... → tokenIds start at 12×256 = 3072
 *          - New levels: e.g. L11+ → tokenIds within same card type range
 *
 *          Security model:
 *          - User submits operation signed by GAME_SERVER_ROLE
 *          - Operation includes nonce, deadline, and user address
 *          - Manager takes $CLASH BEFORE minting (atomic revert on failure)
 *          - On-chain pricing tables prevent cost forgery
 *          - ReentrancyGuard on all state-changing functions
 *          - Replay protection via usedOperations mapping
 */
contract ClashCardManager is AccessControl, ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;

    bytes32 public constant OPERATOR_ROLE    = keccak256("OPERATOR_ROLE");
    bytes32 public constant GAME_SERVER_ROLE = keccak256("GAME_SERVER_ROLE");

    IERC20     public immutable clashToken;
    IERC1155   public immutable clashCards;
    ClashCards public immutable cards;

    address public treasury;

    // ============================================================
    //                      CONFIGURATION
    // ============================================================

    enum ChestType { Silver, Gold, Magical }

    /// @notice Fixed multiplier for token ID encoding (supports 256 levels per type).
    uint256 public constant MAX_LEVELS_PER_TYPE = 256;

    /// @notice Maximum number of card types supported.
    uint256 public constant MAX_CARD_TYPES = 256;

    /// @notice Current max level (admin can increase via setMaxLevel).
    uint256 public maxLevel = 10;

    /// @notice Set of valid card type IDs (admin-managed via addCardType).
    mapping(uint256 => bool) public cardTypeExists;

    /// @dev Ordered list of card type IDs (for enumeration).
    uint256[] public cardTypeIds;

    /// @notice $CLASH cost per upgrade level.
    ///         Index 0 = L1->L2, Index N-1 = L_{N-1}->L_N.
    uint256[] public upgradeCosts = [
        10_000_000 ether,    // L1 -> L2
        20_000_000 ether,    // L2 -> L3
        40_000_000 ether,    // L3 -> L4
        80_000_000 ether,    // L4 -> L5
        160_000_000 ether,   // L5 -> L6
        320_000_000 ether,   // L6 -> L7
        640_000_000 ether,   // L7 -> L8
        1_280_000_000 ether, // L8 -> L9
        2_560_000_000 ether  // L9 -> L10
    ];

    /// @notice NFT count required per upgrade level.
    uint256[] public upgradeBurnCounts = [
        10, 40, 80, 160, 320, 640, 1280, 2560, 5120
    ];

    /// @notice $CLASH cost per pack type.
    mapping(bytes32 => uint256) public packCosts;

    /// @notice $CLASH cost per chest type.
    mapping(ChestType => uint256) public chestCosts;

    /// @dev Maps operation hash to processed status (anti-replay).
    mapping(bytes32 => bool) public usedOperations;

    // ============================================================
    //                          TYPES
    // ============================================================

    struct UpgradeRequest {
        address user;
        uint256 cardType;     // Card type ID (0-255)
        uint256 fromLevel;    // 1 to maxLevel-1
        uint256 toLevel;      // fromLevel + 1
        uint256 tokenIdBurn;  // Pre-computed by client
        uint256 tokenIdMint;  // Pre-computed by client
        uint256 burnAmount;   // Pre-computed by client
        uint256 clashCost;
        uint256 nonce;
        uint256 deadline;
    }

    struct PackRequest {
        address user;
        bytes32 packId;
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

    // ============================================================
    //                    EIP-712 TYPE HASHES
    // ============================================================

    bytes32 private constant UPGRADE_TYPEHASH = keccak256(
        "UpgradeRequest(address user,uint256 cardType,uint256 fromLevel,uint256 toLevel,uint256 tokenIdBurn,uint256 tokenIdMint,uint256 burnAmount,uint256 clashCost,uint256 nonce,uint256 deadline)"
    );

    bytes32 private constant PACK_TYPEHASH = keccak256(
        "PackRequest(address user,bytes32 packId,uint256 clashCost,uint256 nonce,uint256 deadline)"
    );

    bytes32 private constant CHEST_TYPEHASH = keccak256(
        "ChestRequest(address user,uint8 chestType,uint256 clashCost,uint256 nonce,uint256 deadline)"
    );

    // ============================================================
    //                          EVENTS
    // ============================================================

    event CardUpgraded(
        address indexed user,
        uint256 indexed cardType,
        uint256 fromLevel,
        uint256 toLevel,
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
        ChestType indexed chestType,
        uint256 clashPaid,
        uint256 cardCount,
        bytes32 operationId
    );

    event TreasuryUpdated(address indexed newTreasury);
    event UpgradeCostUpdated(uint256 fromLevel, uint256 newCost);
    event UpgradeBurnCountUpdated(uint256 fromLevel, uint256 newCount);
    event PackCostUpdated(bytes32 indexed packId, uint256 newCost);
    event ChestCostUpdated(ChestType indexed chestType, uint256 newCost);
    event GameServerUpdated(address indexed gameServer, bool granted);
    event CardTypeAdded(uint256 indexed cardTypeId);
    event CardTypeRemoved(uint256 indexed cardTypeId);
    event MaxLevelUpdated(uint256 newMaxLevel);

    // ============================================================
    //                       CUSTOM ERRORS
    // ============================================================

    error InvalidAddress();
    error InvalidLevel();
    error InvalidCost();
    error InvalidBurnCount();
    error InvalidCardType(uint256 cardTypeId);
    error CardTypeAlreadyExists(uint256 cardTypeId);
    error CardTypeDoesNotExist(uint256 cardTypeId);
    error CannotDecreaseMaxLevel(uint256 currentMax, uint256 requestedMax);
    error ExceedsMaxCardTypes();
    error ExceedsMaxLevels();
    error Expired(uint256 currentTime, uint256 deadline);
    error WrongUser(address expected, address actual);
    error AlreadyProcessed(bytes32 operationId);
    error InvalidSignature(address recovered);
    error EmptyArray();
    error ArrayLengthMismatch(uint256 tokenIdsLength, uint256 amountsLength);
    error PackTooLarge(uint256 size, uint256 max);
    error ChestTooLarge(uint256 size, uint256 max);
    error UnknownPack(bytes32 packId);
    error UnknownChest(ChestType chestType);
    error CostMismatch(uint256 expected, uint256 actual);
    error InvalidMintTokenId(uint256 expected, uint256 actual);

    // ============================================================
    //                        CONSTRUCTOR
    // ============================================================

    constructor(
        address clashToken_,
        address clashCards_,
        address treasury_,
        address admin_
    ) EIP712("ClashCardManager", "1") {
        if (clashToken_ == address(0)) revert InvalidAddress();
        if (clashCards_ == address(0)) revert InvalidAddress();
        if (treasury_   == address(0)) revert InvalidAddress();
        if (admin_      == address(0)) revert InvalidAddress();

        clashToken = IERC20(clashToken_);
        clashCards = IERC1155(clashCards_);
        cards      = ClashCards(clashCards_);
        treasury   = treasury_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(OPERATOR_ROLE, admin_);
        _grantRole(GAME_SERVER_ROLE, admin_);

        // Register initial 12 card types
        for (uint256 i = 0; i < 12; i++) {
            cardTypeExists[i] = true;
            cardTypeIds.push(i);
        }

        // Default chest pricing (per user spec, unchanged)
        chestCosts[ChestType.Silver]  = 1_000_000 ether;
        chestCosts[ChestType.Gold]    = 3_000_000 ether;
        chestCosts[ChestType.Magical] = 5_000_000 ether;
    }

    // ============================================================
    //                     CORE OPERATIONS
    // ============================================================

    function upgradeCard(
        UpgradeRequest calldata request,
        bytes calldata signature
    ) external nonReentrant {
        // ---- Validate request ----
        if (block.timestamp > request.deadline) {
            revert Expired(block.timestamp, request.deadline);
        }
        if (request.user != msg.sender) {
            revert WrongUser(request.user, msg.sender);
        }
        if (request.toLevel != request.fromLevel + 1) revert InvalidLevel();
        if (request.toLevel > maxLevel) revert InvalidLevel();
        if (request.clashCost == 0) revert InvalidCost();
        if (!cardTypeExists[request.cardType]) {
            revert CardTypeDoesNotExist(request.cardType);
        }

        // CRITICAL: validate tokenIdMint matches expected (anti-forgery)
        uint256 expectedMintId = tokenIdOf(request.cardType, request.toLevel);
        if (request.tokenIdMint != expectedMintId) {
            revert InvalidMintTokenId(expectedMintId, request.tokenIdMint);
        }

        // CRITICAL: validate cost matches on-chain pricing
        uint256 expectedCost = upgradeCosts[request.fromLevel - 1];
        if (request.clashCost != expectedCost) {
            revert CostMismatch(expectedCost, request.clashCost);
        }

        // CRITICAL: validate burn count matches on-chain
        uint256 expectedBurn = upgradeBurnCounts[request.fromLevel - 1];
        if (request.burnAmount != expectedBurn) {
            revert InvalidBurnCount();
        }

        // ---- Replay protection ----
        bytes32 opId = keccak256(abi.encode(request));
        if (usedOperations[opId]) revert AlreadyProcessed(opId);
        usedOperations[opId] = true;

        // ---- Signature verification ----
        _verifySignature(_hashTypedDataV4(keccak256(abi.encode(
            UPGRADE_TYPEHASH,
            request.user,
            request.cardType,
            request.fromLevel,
            request.toLevel,
            request.tokenIdBurn,
            request.tokenIdMint,
            request.burnAmount,
            request.clashCost,
            request.nonce,
            request.deadline
        ))), signature);

        // ---- Execute (atomic) ----
        clashCards.safeTransferFrom(
            request.user, address(this), request.tokenIdBurn, request.burnAmount, ""
        );
        clashToken.safeTransferFrom(request.user, treasury, request.clashCost);
        cards.mint(request.user, request.tokenIdMint, 1, "");

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

    function buyPack(
        PackRequest calldata request,
        bytes calldata signature,
        uint256[] calldata tokenIds,
        uint256[] calldata amounts
    ) external nonReentrant {
        if (block.timestamp > request.deadline) {
            revert Expired(block.timestamp, request.deadline);
        }
        if (request.user != msg.sender) {
            revert WrongUser(request.user, msg.sender);
        }
        if (request.clashCost == 0) revert InvalidCost();
        if (tokenIds.length != amounts.length) {
            revert ArrayLengthMismatch(tokenIds.length, amounts.length);
        }
        if (tokenIds.length == 0) revert EmptyArray();
        if (tokenIds.length > 50) revert PackTooLarge(tokenIds.length, 50);

        uint256 expectedCost = packCosts[request.packId];
        if (expectedCost == 0) revert UnknownPack(request.packId);
        if (request.clashCost != expectedCost) {
            revert CostMismatch(expectedCost, request.clashCost);
        }

        bytes32 opId = keccak256(abi.encode(
            request, keccak256(abi.encodePacked(tokenIds)), keccak256(abi.encodePacked(amounts))
        ));
        if (usedOperations[opId]) revert AlreadyProcessed(opId);
        usedOperations[opId] = true;

        _verifySignature(_hashTypedDataV4(keccak256(abi.encode(
            PACK_TYPEHASH,
            request.user,
            request.packId,
            request.clashCost,
            request.nonce,
            request.deadline
        ))), signature);

        clashToken.safeTransferFrom(request.user, treasury, request.clashCost);
        cards.mintBatch(request.user, tokenIds, amounts, "");

        uint256 totalCards = 0;
        for (uint256 i = 0; i < amounts.length; i++) {
            totalCards += amounts[i];
        }

        emit PackPurchased(
            request.user, request.packId, request.clashCost, totalCards, opId
        );
    }

    function buyChest(
        ChestRequest calldata request,
        bytes calldata signature,
        uint256[] calldata tokenIds,
        uint256[] calldata amounts
    ) external nonReentrant {
        if (block.timestamp > request.deadline) {
            revert Expired(block.timestamp, request.deadline);
        }
        if (request.user != msg.sender) {
            revert WrongUser(request.user, msg.sender);
        }
        if (request.clashCost == 0) revert InvalidCost();
        if (tokenIds.length != amounts.length) {
            revert ArrayLengthMismatch(tokenIds.length, amounts.length);
        }
        if (tokenIds.length == 0) revert EmptyArray();
        if (tokenIds.length > 200) revert ChestTooLarge(tokenIds.length, 200);

        uint256 expectedCost = chestCosts[request.chestType];
        if (expectedCost == 0) revert UnknownChest(request.chestType);
        if (request.clashCost != expectedCost) {
            revert CostMismatch(expectedCost, request.clashCost);
        }

        bytes32 opId = keccak256(abi.encode(
            request, keccak256(abi.encodePacked(tokenIds)), keccak256(abi.encodePacked(amounts))
        ));
        if (usedOperations[opId]) revert AlreadyProcessed(opId);
        usedOperations[opId] = true;

        _verifySignature(_hashTypedDataV4(keccak256(abi.encode(
            CHEST_TYPEHASH,
            request.user,
            request.chestType,
            request.clashCost,
            request.nonce,
            request.deadline
        ))), signature);

        clashToken.safeTransferFrom(request.user, treasury, request.clashCost);
        cards.mintBatch(request.user, tokenIds, amounts, "");

        uint256 totalCards = 0;
        for (uint256 i = 0; i < amounts.length; i++) {
            totalCards += amounts[i];
        }

        emit ChestPurchased(
            request.user, request.chestType, request.clashCost, totalCards, opId
        );
    }

    // ============================================================
    //                    TOKEN ID HELPERS
    // ============================================================

    /**
     * @notice Compute token ID from card type and level.
     * @dev    tokenId = (cardType × 256) + (level - 1).
     *         Supports up to 256 card types × 256 levels = 65,536 unique tokens.
     */
    function tokenIdOf(uint256 cardType, uint256 level) public pure returns (uint256) {
        return (cardType * MAX_LEVELS_PER_TYPE) + (level - 1);
    }

    /**
     * @notice Extract card type from token ID.
     */
    function cardTypeOf(uint256 tokenId) public pure returns (uint256) {
        return tokenId / MAX_LEVELS_PER_TYPE;
    }

    /**
     * @notice Extract level from token ID.
     */
    function levelOf(uint256 tokenId) public pure returns (uint256) {
        return (tokenId % MAX_LEVELS_PER_TYPE) + 1;
    }

    // ============================================================
    //                    PRICING GETTERS
    // ============================================================

    function getUpgradeCost(uint256 fromLevel) external view returns (uint256) {
        if (fromLevel < 1 || fromLevel >= maxLevel) revert InvalidLevel();
        return upgradeCosts[fromLevel - 1];
    }

    function getUpgradeBurnCount(uint256 fromLevel) external view returns (uint256) {
        if (fromLevel < 1 || fromLevel >= maxLevel) revert InvalidLevel();
        return upgradeBurnCounts[fromLevel - 1];
    }

    function getCardTypeCount() external view returns (uint256) {
        return cardTypeIds.length;
    }

    // ============================================================
    //                    ADMIN FUNCTIONS
    // ============================================================

    function setTreasury(address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newTreasury == address(0)) revert InvalidAddress();
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    function setUpgradeCost(uint256 fromLevel, uint256 newCost) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (fromLevel < 1 || fromLevel >= maxLevel) revert InvalidLevel();
        if (newCost == 0) revert InvalidCost();
        upgradeCosts[fromLevel - 1] = newCost;
        emit UpgradeCostUpdated(fromLevel, newCost);
    }

    function setUpgradeBurnCount(uint256 fromLevel, uint256 newCount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (fromLevel < 1 || fromLevel >= maxLevel) revert InvalidLevel();
        if (newCount == 0) revert InvalidBurnCount();
        upgradeBurnCounts[fromLevel - 1] = newCount;
        emit UpgradeBurnCountUpdated(fromLevel, newCount);
    }

    function setPackCost(bytes32 packId, uint256 newCost) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newCost == 0) revert InvalidCost();
        packCosts[packId] = newCost;
        emit PackCostUpdated(packId, newCost);
    }

    function setChestCost(ChestType chestType, uint256 newCost) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newCost == 0) revert InvalidCost();
        chestCosts[chestType] = newCost;
        emit ChestCostUpdated(chestType, newCost);
    }

    function setGameServer(address gameServer, bool granted) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (gameServer == address(0)) revert InvalidAddress();
        if (granted) {
            _grantRole(GAME_SERVER_ROLE, gameServer);
        } else {
            _revokeRole(GAME_SERVER_ROLE, gameServer);
        }
        emit GameServerUpdated(gameServer, granted);
    }

    /**
     * @notice Register a new card type.
     * @param  cardTypeId Unique card type ID (0-255).
     * @dev    Card type IDs must be unique. Initial 12 types (0-11) are registered in constructor.
     *         New types start at ID 12. Token IDs: 12×256 = 3072+.
     */
    function addCardType(uint256 cardTypeId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (cardTypeExists[cardTypeId]) revert CardTypeAlreadyExists(cardTypeId);
        if (cardTypeId >= MAX_CARD_TYPES) revert ExceedsMaxCardTypes();
        if (cardTypeIds.length >= MAX_CARD_TYPES) revert ExceedsMaxCardTypes();

        cardTypeExists[cardTypeId] = true;
        cardTypeIds.push(cardTypeId);
        emit CardTypeAdded(cardTypeId);
    }

    /**
     * @notice Remove a card type (mark as invalid).
     * @param  cardTypeId Card type ID to remove.
     * @dev    Cannot remove card types with existing minted tokens.
     *         Existing tokens remain in users' wallets but new operations on this type will revert.
     */
    function removeCardType(uint256 cardTypeId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!cardTypeExists[cardTypeId]) revert CardTypeDoesNotExist(cardTypeId);

        cardTypeExists[cardTypeId] = false;
        // Note: we don't remove from cardTypeIds array (preserves history)
        emit CardTypeRemoved(cardTypeId);
    }

    /**
     * @notice Increase the max level (one-way, cannot decrease).
     * @param  newMaxLevel New max level (must be > current maxLevel, up to 256).
     * @dev    Adds default pricing for new levels (2x previous cost/burn).
     *         Admin can adjust new levels' pricing via setUpgradeCost/setUpgradeBurnCount.
     */
    function setMaxLevel(uint256 newMaxLevel) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newMaxLevel <= maxLevel) {
            revert CannotDecreaseMaxLevel(maxLevel, newMaxLevel);
        }
        if (newMaxLevel > MAX_LEVELS_PER_TYPE) revert ExceedsMaxLevels();

        // Extend pricing arrays with 2x defaults
        while (upgradeCosts.length < newMaxLevel - 1) {
            uint256 lastCost = upgradeCosts[upgradeCosts.length - 1];
            upgradeCosts.push(lastCost * 2);

            uint256 lastBurn = upgradeBurnCounts[upgradeBurnCounts.length - 1];
            upgradeBurnCounts.push(lastBurn * 2);
        }

        maxLevel = newMaxLevel;
        emit MaxLevelUpdated(newMaxLevel);
    }

    // ============================================================
    //                  ERC-1155 RECEIVER HOOKS
    // ============================================================

    function onERC1155Received(
        address, address, uint256, uint256, bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address, address, uint256[] calldata, uint256[] calldata, bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }

    // ============================================================
    //                  INTERNAL: SIGNATURE
    // ============================================================

    function _verifySignature(bytes32 digest, bytes calldata signature) internal view {
        address recovered = ECDSA.recover(digest, signature);
        if (!hasRole(GAME_SERVER_ROLE, recovered)) {
            revert InvalidSignature(recovered);
        }
    }

    /**
     * @notice Compute the EIP-712 digest hash for a struct hash.
     */
    function digestHash(bytes32 structHash) external view returns (bytes32) {
        return _hashTypedDataV4(structHash);
    }
}
