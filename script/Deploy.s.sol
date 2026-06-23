// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/ClashCards.sol";
import "../src/ClashCardManager.sol";

/**
 * @title Deploy Script
 * @notice Deploys ClashCards + ClashCardManager to Base mainnet
 * @dev Usage:
 *   forge script script/Deploy.s.sol:Deploy --rpc-url $BASE_RPC_URL --broadcast --verify
 *
 * Environment variables required:
 *   PRIVATE_KEY              - deployer private key
 *   BASE_RPC_URL             - Base mainnet RPC
 *   BASESCAN_API_KEY         - for contract verification
 *   CLASH_TOKEN_ADDRESS      - $CLASH ERC-20 token address
 *   TREASURY_ADDRESS         - treasury wallet
 *   ROYALTY_RECEIVER         - royalty receiver (usually treasury)
 *   ADMIN_ADDRESS            - admin wallet
 *   BASE_URI                 - metadata base URI
 */
contract Deploy is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address clashToken = vm.envAddress("CLASH_TOKEN_ADDRESS");
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        address royaltyReceiver = vm.envAddress("ROYALTY_RECEIVER");
        address admin = vm.envAddress("ADMIN_ADDRESS");
        string memory baseURI = vm.envString("BASE_URI");

        console.log("Deployer:", deployer);
        console.log("ClashToken:", clashToken);
        console.log("Treasury:", treasury);
        console.log("Royalty Receiver:", royaltyReceiver);
        console.log("Admin:", admin);
        console.log("Base URI:", baseURI);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy ClashCards (NFT)
        ClashCards clashCards = new ClashCards(
            baseURI,
            royaltyReceiver,
            admin
        );
        console.log("ClashCards deployed at:", address(clashCards));

        // 2. Deploy ClashCardManager
        ClashCardManager manager = new ClashCardManager(
            clashToken,
            address(clashCards),
            treasury,
            admin
        );
        console.log("ClashCardManager deployed at:", address(manager));

        // 3. Grant MINTER_ROLE + BURNER_ROLE on ClashCards to manager
        clashCards.grantRole(clashCards.MINTER_ROLE(), address(manager));
        clashCards.grantRole(clashCards.BURNER_ROLE(), address(manager));
        console.log("Granted MINTER_ROLE and BURNER_ROLE to manager");

        // 4. Grant GAME_SERVER_ROLE on manager to admin (will be moved to game server later)
        manager.grantRole(manager.GAME_SERVER_ROLE(), admin);
        console.log("Granted GAME_SERVER_ROLE to admin (temporary)");

        vm.stopBroadcast();

        // Output summary
        console.log("\n=== DEPLOYMENT SUMMARY ===");
        console.log("ClashCards:        ", address(clashCards));
        console.log("ClashCardManager:  ", address(manager));
        console.log("\nUpdate these in your edge function env vars:");
        console.log("CLASH_CARDS_ADDRESS=", address(clashCards));
        console.log("CLASH_CARD_MANAGER_ADDRESS=", address(manager));
    }
}
