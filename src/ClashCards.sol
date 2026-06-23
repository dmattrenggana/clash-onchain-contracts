// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/common/ERC2981.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title ClashCards
 * @notice ERC-1155 NFT for Clash Onchain cards
 * @dev 120 token IDs = (card_type_id × 10) + (level - 1) for 0-119
 *      Level 1-10 of 12 card types
 *      Royalty 5% via ERC-2981
 */
contract ClashCards is ERC1155, ERC1155Supply, AccessControl, ERC2981 {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    string public name = "Clash Onchain Cards";
    string public symbol = "CLASHCARD";

    // Base URI for token metadata
    string private _baseURI;

    event BaseURIUpdated(string newBaseURI);

    constructor(
        string memory baseURI_,
        address royaltyReceiver_,
        address admin_
    ) ERC1155(baseURI_) {
        _baseURI = baseURI_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(MINTER_ROLE, admin_);
        _grantRole(BURNER_ROLE, admin_);
        // Set 5% royalty
        _setDefaultRoyalty(royaltyReceiver_, 500);
    }

    /**
     * @notice Set base URI (admin only)
     * @param newBaseURI New base URI for token metadata
     */
    function setBaseURI(string memory newBaseURI) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _baseURI = newBaseURI;
        emit BaseURIUpdated(newBaseURI);
    }

    /**
     * @notice Mint cards (minter only)
     * @param to Recipient address
     * @param tokenId Token ID to mint
     * @param amount Amount to mint
     * @param data Additional data (for hooks)
     */
    function mint(
        address to,
        uint256 tokenId,
        uint256 amount,
        bytes memory data
    ) external onlyRole(MINTER_ROLE) {
        _mint(to, tokenId, amount, data);
    }

    /**
     * @notice Batch mint (minter only)
     * @param to Recipient address
     * @param tokenIds Array of token IDs
     * @param amounts Array of amounts
     * @param data Additional data
     */
    function mintBatch(
        address to,
        uint256[] memory tokenIds,
        uint256[] memory amounts,
        bytes memory data
    ) external onlyRole(MINTER_ROLE) {
        _mintBatch(to, tokenIds, amounts, data);
    }

    /**
     * @notice Burn cards (burner only)
     * @param from Address to burn from
     * @param tokenId Token ID
     * @param amount Amount to burn
     */
    function burn(
        address from,
        uint256 tokenId,
        uint256 amount
    ) external onlyRole(BURNER_ROLE) {
        _burn(from, tokenId, amount);
    }

    /**
     * @notice Batch burn (burner only)
     * @param from Address to burn from
     * @param tokenIds Array of token IDs
     * @param amounts Array of amounts
     */
    function burnBatch(
        address from,
        uint256[] memory tokenIds,
        uint256[] memory amounts
    ) external onlyRole(BURNER_ROLE) {
        _burnBatch(from, tokenIds, amounts);
    }

    /**
     * @notice Get URI for token
     * @param tokenId Token ID
     * @return Token URI
     */
    function uri(uint256 tokenId) public view override returns (string memory) {
        return string(abi.encodePacked(_baseURI, Strings.toString(tokenId), ".json"));
    }

    /**
     * @notice Returns total supply for a token
     * @param tokenId Token ID
     * @return Total supply
     */
    function totalSupply(uint256 tokenId) public view override returns (uint256) {
        return super.totalSupply(tokenId);
    }

    // Required overrides
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
