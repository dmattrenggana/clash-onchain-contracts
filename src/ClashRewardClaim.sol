// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
contract ClashRewardClaim is Ownable, ReentrancyGuard {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;
    IERC20 public clashToken;
    address public signerAddress;
    
    // Mapping to keep track of used nonces to prevent replay attacks
    mapping(address => mapping(uint256 => bool)) public usedNonces;
    // Events
    event RewardClaimed(address indexed player, uint256 amount, uint256 nonce);
    event CardUpgraded(address indexed player, string cardId, uint256 cost);
    event SignerUpdated(address indexed newSigner);
    /**
     * @param _tokenAddress The address of the existing $CLASH ERC20 token.
     * @param _signerAddress The address of the backend wallet that will sign the rewards.
     */
    constructor(address _tokenAddress, address _signerAddress) Ownable(msg.sender) {
        require(_tokenAddress != address(0), "Invalid token address");
        require(_signerAddress != address(0), "Invalid signer address");
        clashToken = IERC20(_tokenAddress);
        signerAddress = _signerAddress;
    }
    /**
     * @dev Claim reward with a valid backend signature.
     * @param amount The amount of $CLASH tokens won.
     * @param nonce A unique ID for this specific match/reward to prevent double claiming.
     * @param signature The ECDSA signature from the backend admin.
     */
    function claimReward(uint256 amount, uint256 nonce, bytes memory signature) external nonReentrant {
        require(amount > 0, "Amount must be greater than 0");
        require(!usedNonces[msg.sender][nonce], "Reward already claimed or invalid nonce");
        // 1. Recreate the message hash that the backend signed
        bytes32 messageHash = keccak256(abi.encodePacked(msg.sender, amount, nonce, address(this)));
        bytes32 ethSignedMessageHash = messageHash.toEthSignedMessageHash();
        // 2. Recover the signer address from the signature
        address recoveredSigner = ethSignedMessageHash.recover(signature);
        
        // 3. Verify the signer is the authorized backend admin
        require(recoveredSigner == signerAddress, "Invalid signature");
        // 4. Mark nonce as used and transfer tokens
        usedNonces[msg.sender][nonce] = true;
        
        // Ensure the contract has enough balance
        require(clashToken.balanceOf(address(this)) >= amount, "Insufficient reward pool balance");
        
        // Transfer tokens to the player
        bool success = clashToken.transfer(msg.sender, amount);
        require(success, "Token transfer failed");
        emit RewardClaimed(msg.sender, amount, nonce);
    }
    /**
     * @dev Pay to upgrade a card on-chain.
     * IMPORTANT: The player must have called `approve()` on the $CLASH token contract first.
     * @param cardId The string ID of the card being upgraded (e.g. "knight")
     * @param cost The amount of $CLASH required for the upgrade
     */
    function upgradeCard(string calldata cardId, uint256 cost) external nonReentrant {
        require(cost > 0, "Cost must be greater than 0");
        require(bytes(cardId).length > 0, "Card ID cannot be empty");
        // Transfer tokens FROM the player TO this contract (acts as a treasury)
        // Player MUST approve this contract address on the ERC20 token first!
        bool success = clashToken.transferFrom(msg.sender, address(this), cost);
        require(success, "Payment failed. Did you approve() the token?");
        // Emit event for the backend/subgraph to listen and update the database
        emit CardUpgraded(msg.sender, cardId, cost);
    }
    /**
     * @dev Admin can update the signer address if the backend key is compromised.
     */
    function setSignerAddress(address _newSigner) external onlyOwner {
        require(_newSigner != address(0), "Invalid signer address");
        signerAddress = _newSigner;
        emit SignerUpdated(_newSigner);
    }
    /**
     * @dev Admin can withdraw collected/stuck tokens from the treasury.
     */
    function withdrawTokens(uint256 amount) external onlyOwner {
        require(clashToken.transfer(owner(), amount), "Transfer failed");
    }
}