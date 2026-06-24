// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/common/ERC2981.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title  ClashCards
 * @notice ERC-1155 NFT contract for Clash Onchain cards.
 * @dev    - 120 unique token IDs = (cardType × 10) + (level - 1), range 0-119
 *          - Card types: 12 (Knight, Archer, ..., Incubus)
 *          - Levels per type: 10 (L1-L10)
 *          - Royalty: 5% via ERC-2981
 *          - Minting/Burning restricted to MANAGER_ROLE
 *
 *          Token ID encoding (locked 2026-06-24):
 *          ┌──────────────┬──────────┬───────────┐
 *          │  cardType    │  level   │  tokenId  │
 *          ├──────────────┼──────────┼───────────┤
 *          │  0 (Knight)  │  1       │  0        │
 *          │  0 (Knight)  │  10      │  9        │
 *          │  3 (Wyvern)  │  1       │  30       │
 *          │  11 (Incubus)│  10      │  119      │
 *          └──────────────┴──────────┴───────────┘
 */
contract ClashCards is ERC1155, ERC1155Supply, AccessControl, ERC2981 {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    string public name = "Clash Onchain Cards";
    string public symbol = "CLASHCARD";

    string private _baseURI;

    event BaseURIUpdated(string newBaseURI);

    error InvalidAddress();
    error InvalidBaseURI();

    constructor(
        string memory baseURI_,
        address royaltyReceiver_,
        address admin_
    ) ERC1155(baseURI_) {
        if (royaltyReceiver_ == address(0)) revert InvalidAddress();
        if (admin_ == address(0)) revert InvalidAddress();
        if (bytes(baseURI_).length == 0) revert InvalidBaseURI();

        _baseURI = baseURI_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(MINTER_ROLE, admin_);
        _grantRole(BURNER_ROLE, admin_);

        // 5% royalty (500 basis points)
        _setDefaultRoyalty(royaltyReceiver_, 500);
    }

    // ============================================================
    //                      ADMIN FUNCTIONS
    // ============================================================

    /**
     * @notice Update the base URI for token metadata.
     * @param  newBaseURI New base URI (e.g. `https://...nft-assets/metadata/`).
     */
    function setBaseURI(string calldata newBaseURI) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bytes(newBaseURI).length == 0) revert InvalidBaseURI();
        _baseURI = newBaseURI;
        emit BaseURIUpdated(newBaseURI);
    }

    // ============================================================
    //                    MINT / BURN FUNCTIONS
    // ============================================================

    /**
     * @notice Mint cards to a recipient.
     * @param  to      Recipient address.
     * @param  tokenId Token ID to mint.
     * @param  amount  Amount to mint.
     * @param  data    Additional data (for receiver hooks).
     */
    function mint(
        address to,
        uint256 tokenId,
        uint256 amount,
        bytes calldata data
    ) external onlyRole(MINTER_ROLE) {
        _mint(to, tokenId, amount, data);
    }

    /**
     * @notice Batch mint multiple card types in one transaction.
     * @param  to       Recipient address.
     * @param  tokenIds Array of token IDs to mint.
     * @param  amounts  Array of amounts to mint (parallel to tokenIds).
     * @param  data     Additional data.
     */
    function mintBatch(
        address to,
        uint256[] calldata tokenIds,
        uint256[] calldata amounts,
        bytes calldata data
    ) external onlyRole(MINTER_ROLE) {
        _mintBatch(to, tokenIds, amounts, data);
    }

    /**
     * @notice Burn cards from a holder.
     * @param  from    Holder address.
     * @param  tokenId Token ID to burn.
     * @param  amount  Amount to burn.
     */
    function burn(
        address from,
        uint256 tokenId,
        uint256 amount
    ) external onlyRole(BURNER_ROLE) {
        _burn(from, tokenId, amount);
    }

    /**
     * @notice Batch burn multiple card types in one transaction.
     * @param  from     Holder address.
     * @param  tokenIds Array of token IDs to burn.
     * @param  amounts  Array of amounts to burn (parallel to tokenIds).
     */
    function burnBatch(
        address from,
        uint256[] calldata tokenIds,
        uint256[] calldata amounts
    ) external onlyRole(BURNER_ROLE) {
        _burnBatch(from, tokenIds, amounts);
    }

    // ============================================================
    //                       VIEW FUNCTIONS
    // ============================================================

    /**
     * @notice Returns the metadata URI for a given token ID.
     * @param  tokenId Token ID.
     * @return Token metadata URI (e.g. `https://.../metadata/30.json`).
     */
    function uri(uint256 tokenId) public view override returns (string memory) {
        return string.concat(_baseURI, Strings.toString(tokenId), ".json");
    }

    /**
     * @notice Returns the total supply for a token ID.
     * @param  tokenId Token ID.
     * @return Total supply minted (minus burned).
     */
    function totalSupply(uint256 tokenId) public view override returns (uint256) {
        return super.totalSupply(tokenId);
    }

    // ============================================================
    //                  REQUIRED OVERRIDES
    // ============================================================

    function _update(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory values
    ) internal override(ERC1155, ERC1155Supply) {
        super._update(from, to, ids, values);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC1155, ERC2981, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
