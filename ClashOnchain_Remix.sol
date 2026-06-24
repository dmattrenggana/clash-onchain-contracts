// SPDX-License-Identifier: MIT
// =====================================================================
//   Clash Onchain NFT + $CLASH Manager (Clean, Self-Contained)
//   Compatible with Remix IDE (no external imports, no via-ir needed).
//
//   COMPILER SETTINGS IN REMIX:
//     - Solidity version: 0.8.20
//     - Optimizer: enabled (200 runs recommended)
//     - No special flags needed
//
//   Contains:
//     - ClashCards (ERC-1155 NFT, 5% royalty, role-based mint/burn)
//     - ClashCardManager (atomic $CLASH + NFT ops, EIP-712 signed)
//
//   Token ID: (cardType × 256) + (level - 1)
//   Initial: 12 card types (0-11), max level 10, 120 unique tokens
//   Capacity: 256 card types × 256 levels = 65,536 tokens
//
//   DEPLOYMENT IN REMIX:
//     1. Paste this file in Remix (File Explorer → New File → Clash.sol)
//     2. Compiler: 0.8.20 (default optimizer is fine)
//     3. Click "Compile Clash.sol"
//     4. Deploy ClashCards first (constructor: baseURI, royaltyReceiver, admin)
//     5. Copy ClashCards address
//     6. Deploy ClashCardManager (constructor: clashToken, clashCards, treasury, admin)
//     7. In console: grant MINTER_ROLE + BURNER_ROLE on ClashCards to manager
// =====================================================================

pragma solidity ^0.8.20;

// =====================================================================
//                       I N T E R F A C E S
// =====================================================================

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IERC1155Receiver {
    function onERC1155Received(address operator, address from, uint256 id, uint256 value, bytes calldata data) external returns (bytes4);
    function onERC1155BatchReceived(address operator, address from, uint256[] calldata ids, uint256[] calldata values, bytes calldata data) external returns (bytes4);
}

// =====================================================================
//                        C L A S H   C A R D S
// =====================================================================

contract ClashCards is IERC1155Receiver {

    // ----- State -----
    string public name = "Clash Onchain Cards";
    string public symbol = "CLASHCARD";
    string private _baseURI;

    address public admin;
    address public royaltyReceiver;
    uint96  public royaltyFeeBps = 500;  // 5%

    // ERC-1155 storage
    mapping(uint256 => mapping(address => uint256)) public balanceOf;
    mapping(address => mapping(address => bool)) public isApprovedForAll;
    mapping(uint256 => uint256) public totalSupply;

    // Roles
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    mapping(bytes32 => mapping(address => bool)) public hasRole;

    // ----- Events -----
    event TransferSingle(address indexed operator, address indexed from, address indexed to, uint256 id, uint256 value);
    event TransferBatch(address indexed operator, address indexed from, address indexed to, uint256[] ids, uint256[] values);
    event ApprovalForAll(address indexed account, address indexed operator, bool approved);
    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);
    event BaseURIUpdated(string newBaseURI);

    // ----- Modifiers -----
    modifier onlyRole(bytes32 role) {
        require(hasRole[role][msg.sender], "Missing role");
        _;
    }

    // ----- Constructor -----
    constructor(
        string memory baseURI_,
        address royaltyReceiver_,
        address admin_
    ) {
        require(bytes(baseURI_).length > 0, "Empty baseURI");
        require(royaltyReceiver_ != address(0), "Invalid royalty receiver");
        require(admin_ != address(0), "Invalid admin");

        _baseURI = baseURI_;
        royaltyReceiver = royaltyReceiver_;
        admin = admin_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(MINTER_ROLE, admin_);
        _grantRole(BURNER_ROLE, admin_);
    }

    // ----- Role Management -----
    function grantRole(bytes32 role, address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(role, account);
    }

    function revokeRole(bytes32 role, address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(role, account);
    }

    function _grantRole(bytes32 role, address account) internal {
        if (!hasRole[role][account]) {
            hasRole[role][account] = true;
            emit RoleGranted(role, account, msg.sender);
        }
    }

    function _revokeRole(bytes32 role, address account) internal {
        if (hasRole[role][account]) {
            hasRole[role][account] = false;
            emit RoleRevoked(role, account, msg.sender);
        }
    }

    // ----- Admin -----
    function setBaseURI(string calldata newBaseURI) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(bytes(newBaseURI).length > 0, "Empty baseURI");
        _baseURI = newBaseURI;
        emit BaseURIUpdated(newBaseURI);
    }

    function setRoyaltyReceiver(address newReceiver) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newReceiver != address(0), "Invalid receiver");
        royaltyReceiver = newReceiver;
    }

    // ----- Mint / Burn -----
    function mint(address to, uint256 id, uint256 amount, bytes calldata data) external onlyRole(MINTER_ROLE) {
        require(to != address(0), "Invalid to");
        balanceOf[id][to] += amount;
        totalSupply[id] += amount;
        emit TransferSingle(msg.sender, address(0), to, id, amount);
    }

    function mintBatch(address to, uint256[] calldata ids, uint256[] calldata amounts, bytes calldata data) external onlyRole(MINTER_ROLE) {
        require(to != address(0), "Invalid to");
        require(ids.length == amounts.length, "Length mismatch");
        for (uint256 i = 0; i < ids.length; i++) {
            balanceOf[ids[i]][to] += amounts[i];
            totalSupply[ids[i]] += amounts[i];
        }
        emit TransferBatch(msg.sender, address(0), to, ids, amounts);
    }

    function burn(address from, uint256 id, uint256 amount) external onlyRole(BURNER_ROLE) {
        require(from != address(0), "Invalid from");
        require(balanceOf[id][from] >= amount, "Insufficient balance");
        balanceOf[id][from] -= amount;
        totalSupply[id] -= amount;
        emit TransferSingle(msg.sender, from, address(0), id, amount);
    }

    function burnBatch(address from, uint256[] calldata ids, uint256[] calldata amounts) external onlyRole(BURNER_ROLE) {
        require(from != address(0), "Invalid from");
        require(ids.length == amounts.length, "Length mismatch");
        for (uint256 i = 0; i < ids.length; i++) {
            require(balanceOf[ids[i]][from] >= amounts[i], "Insufficient balance");
            balanceOf[ids[i]][from] -= amounts[i];
            totalSupply[ids[i]] -= amounts[i];
        }
        emit TransferBatch(msg.sender, from, address(0), ids, amounts);
    }

    // ----- Transfers -----
    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata data) external {
        require(from != address(0), "Invalid from");
        require(to != address(0), "Invalid to");
        require(
            msg.sender == from || isApprovedForAll[from][msg.sender],
            "Not authorized"
        );
        require(balanceOf[id][from] >= amount, "Insufficient balance");

        balanceOf[id][from] -= amount;
        balanceOf[id][to] += amount;

        emit TransferSingle(msg.sender, from, to, id, amount);
    }

    function safeBatchTransferFrom(address from, address to, uint256[] calldata ids, uint256[] calldata amounts, bytes calldata data) external {
        require(from != address(0), "Invalid from");
        require(to != address(0), "Invalid to");
        require(
            msg.sender == from || isApprovedForAll[from][msg.sender],
            "Not authorized"
        );
        require(ids.length == amounts.length, "Length mismatch");

        for (uint256 i = 0; i < ids.length; i++) {
            require(balanceOf[ids[i]][from] >= amounts[i], "Insufficient balance");
            balanceOf[ids[i]][from] -= amounts[i];
            balanceOf[ids[i]][to] += amounts[i];
        }

        emit TransferBatch(msg.sender, from, to, ids, amounts);
    }

    // ----- Views -----
    function uri(uint256 tokenId) external view returns (string memory) {
        return string(abi.encodePacked(_baseURI, _toString(tokenId), ".json"));
    }

    function royaltyInfo(uint256, uint256 salePrice) external view returns (address receiver, uint256 amount) {
        receiver = royaltyReceiver;
        amount = (salePrice * royaltyFeeBps) / 10000;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return (
            interfaceId == 0x01ffc9a7 ||  // ERC-165
            interfaceId == 0xd9b67a26 ||  // ERC-1155
            interfaceId == 0x2a55205a     // ERC-2981
        );
    }

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) { digits++; temp /= 10; }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    // ----- Receiver Hooks -----
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure override returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata) external pure override returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }
}

// =====================================================================
//                  C L A S H   C A R D   M A N A G E R
// =====================================================================

contract ClashCardManager {

    // ----- Reentrancy Guard -----
    uint256 private _locked;
    modifier nonReentrant() {
        require(_locked == 0, "Reentrancy");
        _locked = 1;
        _;
        _locked = 0;
    }

    // ----- Roles -----
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 public constant OPERATOR_ROLE     = keccak256("OPERATOR_ROLE");
    bytes32 public constant GAME_SERVER_ROLE  = keccak256("GAME_SERVER_ROLE");
    mapping(bytes32 => mapping(address => bool)) public hasRole;

    // ----- Token references -----
    IERC20    public immutable clashToken;
    ClashCards public immutable cards;
    address   public treasury;
    address   public admin;

    // ----- EIP-712 -----
    bytes32 public immutable DOMAIN_SEPARATOR;
    bytes32 private constant EIP712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 private constant UPGRADE_TYPEHASH = keccak256(
        "UpgradeRequest(address user,uint256 cardType,uint256 fromLevel,uint256 toLevel,uint256 tokenIdBurn,uint256 tokenIdMint,uint256 burnAmount,uint256 clashCost,uint256 nonce,uint256 deadline)"
    );
    bytes32 private constant CHEST_TYPEHASH = keccak256(
        "ChestRequest(address user,uint8 chestType,uint256 clashCost,uint256 nonce,uint256 deadline)"
    );
    bytes32 private constant PACK_TYPEHASH = keccak256(
        "PackRequest(address user,bytes32 packId,uint256 clashCost,uint256 nonce,uint256 deadline)"
    );

    // ----- Card Type Config -----
    uint256 public constant MAX_LEVELS_PER_TYPE = 256;
    uint256 public constant MAX_CARD_TYPES      = 256;
    uint256 public maxLevel = 10;
    mapping(uint256 => bool) public cardTypeExists;
    uint256[] public cardTypeIds;
    uint256 public cardTypeCount;

    // ----- Pricing (locked per user spec 2026-06-24) -----
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

    uint256[] public upgradeBurnCounts = [
        10, 40, 80, 160, 320, 640, 1280, 2560, 5120
    ];

    enum ChestType { Silver, Gold, Magical }
    mapping(bytes32 => uint256) public packCosts;
    mapping(uint8 => uint256) public chestCosts;

    // ----- Replay Protection -----
    mapping(bytes32 => bool) public usedOperations;

    // ----- Request Types -----
    struct UpgradeRequest {
        address user;
        uint256 cardType;
        uint256 fromLevel;
        uint256 toLevel;
        uint256 tokenIdBurn;
        uint256 tokenIdMint;
        uint256 burnAmount;
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
        uint8    chestType;
        uint256 clashCost;
        uint256 nonce;
        uint256 deadline;
    }

    // ----- Events -----
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
    event PackPurchased(address indexed user, bytes32 indexed packId, uint256 clashPaid, uint256 cardCount, bytes32 operationId);
    event ChestPurchased(address indexed user, uint8 indexed chestType, uint256 clashPaid, uint256 cardCount, bytes32 operationId);
    event TreasuryUpdated(address newTreasury);
    event UpgradeCostUpdated(uint256 fromLevel, uint256 newCost);
    event UpgradeBurnCountUpdated(uint256 fromLevel, uint256 newCount);
    event PackCostUpdated(bytes32 packId, uint256 newCost);
    event ChestCostUpdated(uint8 chestType, uint256 newCost);
    event GameServerUpdated(address gameServer, bool granted);
    event CardTypeAdded(uint256 cardTypeId);
    event CardTypeRemoved(uint256 cardTypeId);
    event MaxLevelUpdated(uint256 newMaxLevel);
    event RoleGranted(bytes32 indexed role, address indexed account);
    event RoleRevoked(bytes32 indexed role, address indexed account);

    // ----- Modifiers -----
    modifier onlyRole(bytes32 role) {
        require(hasRole[role][msg.sender], "Missing role");
        _;
    }

    // ----- Constructor -----
    constructor(
        address clashToken_,
        address clashCards_,
        address treasury_,
        address admin_
    ) {
        require(clashToken_ != address(0), "Invalid token");
        require(clashCards_ != address(0), "Invalid cards");
        require(treasury_   != address(0), "Invalid treasury");
        require(admin_      != address(0), "Invalid admin");

        clashToken = IERC20(clashToken_);
        cards      = ClashCards(clashCards_);
        treasury   = treasury_;
        admin      = admin_;

        DOMAIN_SEPARATOR = keccak256(abi.encode(
            EIP712_DOMAIN_TYPEHASH,
            keccak256("ClashCardManager"),
            keccak256("1"),
            block.chainid,
            address(this)
        ));

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(OPERATOR_ROLE, admin_);
        _grantRole(GAME_SERVER_ROLE, admin_);

        // Register initial 12 card types
        for (uint256 i = 0; i < 12; i++) {
            cardTypeExists[i] = true;
            cardTypeIds.push(i);
        }
        cardTypeCount = 12;

        // Default chest pricing
        chestCosts[uint8(ChestType.Silver)]  = 1_000_000 ether;
        chestCosts[uint8(ChestType.Gold)]    = 3_000_000 ether;
        chestCosts[uint8(ChestType.Magical)] = 5_000_000 ether;
    }

    // ============================================================
    //                     CORE OPERATIONS
    // ============================================================

    function upgradeCard(UpgradeRequest calldata request, bytes calldata signature) external nonReentrant {
        // ---- Validate ----
        require(block.timestamp <= request.deadline, "Expired");
        require(request.user == msg.sender, "Wrong user");
        require(request.toLevel == request.fromLevel + 1, "Invalid level diff");
        require(request.toLevel <= maxLevel, "Exceeds max level");
        require(request.clashCost > 0, "Invalid cost");
        require(cardTypeExists[request.cardType], "Unknown card type");
        _validateUpgradePricing(request);

        // Replay protection
        bytes32 opId = keccak256(abi.encode(request));
        require(!usedOperations[opId], "Already processed");
        usedOperations[opId] = true;

        // Signature verification
        _verifyUpgradeRequest(request, signature);

        // ---- Execute (atomic) ----
        cards.safeTransferFrom(request.user, address(this), request.tokenIdBurn, request.burnAmount, "");
        require(clashToken.transferFrom(request.user, treasury, request.clashCost), "Payment failed");
        cards.mint(request.user, request.tokenIdMint, 1, "");

        emit CardUpgraded(
            request.user, request.cardType, request.fromLevel, request.toLevel,
            request.tokenIdBurn, request.tokenIdMint, request.burnAmount, request.clashCost, opId
        );
    }

    function _validateUpgradePricing(UpgradeRequest calldata request) internal view {
        uint256 expectedMintId = tokenIdOf(request.cardType, request.toLevel);
        require(request.tokenIdMint == expectedMintId, "Invalid mint tokenId");
        uint256 expectedCost = upgradeCosts[request.fromLevel - 1];
        require(request.clashCost == expectedCost, "Cost mismatch");
        uint256 expectedBurn = upgradeBurnCounts[request.fromLevel - 1];
        require(request.burnAmount == expectedBurn, "Burn count mismatch");
    }

    function _verifyUpgradeRequest(UpgradeRequest calldata request, bytes calldata signature) internal view {
        bytes32 structHash = keccak256(abi.encode(
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
        ));
        _verifySignature(_hashTypedData(structHash), signature);
    }

    function buyPack(PackRequest calldata request, bytes calldata signature, uint256[] calldata tokenIds, uint256[] calldata amounts) external nonReentrant {
        require(block.timestamp <= request.deadline, "Expired");
        require(request.user == msg.sender, "Wrong user");
        require(request.clashCost > 0, "Invalid cost");
        require(tokenIds.length == amounts.length, "Length mismatch");
        require(tokenIds.length > 0, "Empty pack");
        require(tokenIds.length <= 50, "Pack too large");

        uint256 expectedCost = packCosts[request.packId];
        require(expectedCost > 0, "Unknown pack");
        require(request.clashCost == expectedCost, "Cost mismatch");

        // PACK L1-ONLY ENFORCEMENT (2026-06-24):
        // Packs must ONLY mint Level 1 cards. Higher levels require
        // upgradeCard() with proper burn + cost.
        for (uint256 i = 0; i < tokenIds.length; i++) {
            require(tokenIds[i] % MAX_LEVELS_PER_TYPE == 0, "Pack: L1 only");
        }

        bytes32 opId = keccak256(abi.encode(request, keccak256(abi.encodePacked(tokenIds)), keccak256(abi.encodePacked(amounts))));
        require(!usedOperations[opId], "Already processed");
        usedOperations[opId] = true;

        _verifyPackRequest(request, signature);

        require(clashToken.transferFrom(request.user, treasury, request.clashCost), "Payment failed");
        cards.mintBatch(request.user, tokenIds, amounts, "");

        uint256 total = 0;
        for (uint256 i = 0; i < amounts.length; i++) total += amounts[i];

        emit PackPurchased(request.user, request.packId, request.clashCost, total, opId);
    }

    function _verifyPackRequest(PackRequest calldata request, bytes calldata signature) internal view {
        bytes32 structHash = keccak256(abi.encode(
            PACK_TYPEHASH,
            request.user,
            request.packId,
            request.clashCost,
            request.nonce,
            request.deadline
        ));
        _verifySignature(_hashTypedData(structHash), signature);
    }

    function buyChest(ChestRequest calldata request, bytes calldata signature, uint256[] calldata tokenIds, uint256[] calldata amounts) external nonReentrant {
        require(block.timestamp <= request.deadline, "Expired");
        require(request.user == msg.sender, "Wrong user");
        require(request.clashCost > 0, "Invalid cost");
        require(tokenIds.length == amounts.length, "Length mismatch");
        require(tokenIds.length > 0, "Empty chest");
        require(tokenIds.length <= 200, "Chest too large");

        uint256 expectedCost = chestCosts[request.chestType];
        require(expectedCost > 0, "Unknown chest");
        require(request.clashCost == expectedCost, "Cost mismatch");

        // CHEST L1-ONLY ENFORCEMENT (2026-06-24):
        // Chests must ONLY mint Level 1 cards. Higher levels (L2+) can
        // ONLY be obtained via upgradeCard(). This prevents users from
        // exploiting the fact that tokenIds[] is not part of the EIP-712
        // signature — a malicious user could otherwise replay a valid
        // chest signature with swapped tokenIds to mint L2+ cards.
        for (uint256 i = 0; i < tokenIds.length; i++) {
            require(tokenIds[i] % MAX_LEVELS_PER_TYPE == 0, "Chest: L1 only");
        }

        bytes32 opId = keccak256(abi.encode(request, keccak256(abi.encodePacked(tokenIds)), keccak256(abi.encodePacked(amounts))));
        require(!usedOperations[opId], "Already processed");
        usedOperations[opId] = true;

        _verifyChestRequest(request, signature);

        require(clashToken.transferFrom(request.user, treasury, request.clashCost), "Payment failed");
        cards.mintBatch(request.user, tokenIds, amounts, "");

        uint256 total = 0;
        for (uint256 i = 0; i < amounts.length; i++) total += amounts[i];

        emit ChestPurchased(request.user, request.chestType, request.clashCost, total, opId);
    }

    function _verifyChestRequest(ChestRequest calldata request, bytes calldata signature) internal view {
        bytes32 structHash = keccak256(abi.encode(
            CHEST_TYPEHASH,
            request.user,
            request.chestType,
            request.clashCost,
            request.nonce,
            request.deadline
        ));
        _verifySignature(_hashTypedData(structHash), signature);
    }

    // ============================================================
    //                    TOKEN ID HELPERS
    // ============================================================

    function tokenIdOf(uint256 cardType, uint256 level) public pure returns (uint256) {
        return (cardType * MAX_LEVELS_PER_TYPE) + (level - 1);
    }

    function cardTypeOf(uint256 tokenId) public pure returns (uint256) {
        return tokenId / MAX_LEVELS_PER_TYPE;
    }

    function levelOf(uint256 tokenId) public pure returns (uint256) {
        return (tokenId % MAX_LEVELS_PER_TYPE) + 1;
    }

    // ============================================================
    //                    PRICING GETTERS
    // ============================================================

    function getUpgradeCost(uint256 fromLevel) external view returns (uint256) {
        require(fromLevel >= 1 && fromLevel < maxLevel, "Invalid level");
        return upgradeCosts[fromLevel - 1];
    }

    function getUpgradeBurnCount(uint256 fromLevel) external view returns (uint256) {
        require(fromLevel >= 1 && fromLevel < maxLevel, "Invalid level");
        return upgradeBurnCounts[fromLevel - 1];
    }

    // ============================================================
    //                    ROLE MANAGEMENT
    // ============================================================

    function grantRole(bytes32 role, address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(role, account);
    }

    function revokeRole(bytes32 role, address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(role, account);
    }

    function _grantRole(bytes32 role, address account) internal {
        if (!hasRole[role][account]) {
            hasRole[role][account] = true;
            emit RoleGranted(role, account);
        }
    }

    function _revokeRole(bytes32 role, address account) internal {
        if (hasRole[role][account]) {
            hasRole[role][account] = false;
            emit RoleRevoked(role, account);
        }
    }

    // ============================================================
    //                    ADMIN FUNCTIONS
    // ============================================================

    function setTreasury(address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newTreasury != address(0), "Invalid treasury");
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    function setUpgradeCost(uint256 fromLevel, uint256 newCost) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(fromLevel >= 1 && fromLevel < maxLevel, "Invalid level");
        require(newCost > 0, "Invalid cost");
        upgradeCosts[fromLevel - 1] = newCost;
        emit UpgradeCostUpdated(fromLevel, newCost);
    }

    function setUpgradeBurnCount(uint256 fromLevel, uint256 newCount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(fromLevel >= 1 && fromLevel < maxLevel, "Invalid level");
        require(newCount > 0, "Invalid count");
        upgradeBurnCounts[fromLevel - 1] = newCount;
        emit UpgradeBurnCountUpdated(fromLevel, newCount);
    }

    function setPackCost(bytes32 packId, uint256 newCost) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newCost > 0, "Invalid cost");
        packCosts[packId] = newCost;
        emit PackCostUpdated(packId, newCost);
    }

    function setChestCost(uint8 chestType, uint256 newCost) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newCost > 0, "Invalid cost");
        chestCosts[chestType] = newCost;
        emit ChestCostUpdated(chestType, newCost);
    }

    function setGameServer(address gameServer, bool granted) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(gameServer != address(0), "Invalid address");
        if (granted) _grantRole(GAME_SERVER_ROLE, gameServer);
        else         _revokeRole(GAME_SERVER_ROLE, gameServer);
        emit GameServerUpdated(gameServer, granted);
    }

    function addCardType(uint256 cardTypeId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(!cardTypeExists[cardTypeId], "Already exists");
        require(cardTypeId < MAX_CARD_TYPES, "Exceeds MAX_CARD_TYPES");
        require(cardTypeIds.length < MAX_CARD_TYPES, "Exceeds MAX_CARD_TYPES");

        cardTypeExists[cardTypeId] = true;
        cardTypeIds.push(cardTypeId);
        cardTypeCount++;
        emit CardTypeAdded(cardTypeId);
    }

    function removeCardType(uint256 cardTypeId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(cardTypeExists[cardTypeId], "Does not exist");
        cardTypeExists[cardTypeId] = false;
        emit CardTypeRemoved(cardTypeId);
    }

    function setMaxLevel(uint256 newMaxLevel) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newMaxLevel > maxLevel, "Can only increase");
        require(newMaxLevel <= MAX_LEVELS_PER_TYPE, "Exceeds MAX_LEVELS_PER_TYPE");

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
    //                  EIP-712 SIGNATURE
    // ============================================================

    function digestHash(bytes32 structHash) external view returns (bytes32) {
        return _hashTypedData(structHash);
    }

    function _hashTypedData(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
    }

    function _verifySignature(bytes32 digest, bytes calldata signature) internal view {
        require(signature.length == 65, "Invalid sig length");
        address recovered = _recover(digest, signature);
        require(hasRole[GAME_SERVER_ROLE][recovered], "Invalid signature");
    }

    function _recover(bytes32 digest, bytes calldata signature) internal pure returns (address) {
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        if (v < 27) v += 27;
        if (v != 27 && v != 28) return address(0);
        return ecrecover(digest, v, r, s);
    }
}
