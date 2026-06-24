// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ClashCards.sol";
import "../src/ClashCardManager.sol";

/**
 * @title Basic ClashCards tests
 * @notice Smoke tests for ClashCards + ClashCardManager
 */
contract ClashCardsTest is Test {
    ClashCards public cards;
    ClashCardManager public manager;
    MockERC20 public token;
    address public admin = address(0x1);
    address public treasury = address(0x2);
    address public royaltyReceiver = address(0x3);
    address public gameServer = address(0x4);
    address public user = address(0x5);

    string public constant BASE_URI = "https://example.com/metadata/";

    function setUp() public {
        // Test contract is the deployer
        token = new MockERC20("Clash", "CLASH");
        // admin is the test contract itself
        admin = address(this);
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

        token.mint(user, 1_000_000 ether);
        vm.prank(user);
        token.approve(address(manager), type(uint256).max);
    }

    function testTokenIdOf() public view {
        // Knight L1 = 0
        assertEq(manager.tokenIdOf(0, 1), 0);
        // Knight L10 = 9
        assertEq(manager.tokenIdOf(0, 10), 9);
        // Wyvern L1 = 3*256 = 768
        assertEq(manager.tokenIdOf(3, 1), 768);
        // Incubus L10 = 11*256 + 9 = 2825
        assertEq(manager.tokenIdOf(11, 10), 2825);
    }

    function testCardTypeOf() public view {
        assertEq(manager.cardTypeOf(0), 0);
        assertEq(manager.cardTypeOf(768), 3);
        assertEq(manager.cardTypeOf(2825), 11);
    }

    function testLevelOf() public view {
        assertEq(manager.levelOf(0), 1);
        assertEq(manager.levelOf(9), 10);
        assertEq(manager.levelOf(2825), 10);  // Incubus L10
    }

    function testMintAndBurn() public {
        // Mint as admin (MINTER_ROLE)
        vm.prank(admin);
        cards.mint(user, 0, 5, "");

        assertEq(cards.balanceOf(user, 0), 5);

        // Burn as admin (BURNER_ROLE)
        vm.prank(admin);
        cards.burn(user, 0, 5);

        assertEq(cards.balanceOf(user, 0), 0);
    }

    function testSetBaseURI() public {
        vm.prank(admin);
        cards.setBaseURI("https://new.com/");
        assertEq(cards.uri(0), "https://new.com/0.json");
        assertEq(cards.uri(119), "https://new.com/119.json");
    }

    function testRoyalty() public view {
        (address receiver, uint256 amount) = cards.royaltyInfo(0, 1 ether);
        assertEq(receiver, royaltyReceiver);
        assertEq(amount, 0.05 ether); // 5%
    }

    function testUnauthorizedMint() public {
        vm.expectRevert();
        vm.prank(user);
        cards.mint(user, 0, 1, "");
    }

    function testSupportsInterface() public view {
        // ERC-1155
        assertTrue(cards.supportsInterface(0xd9b67a26));
        // ERC-2981
        assertTrue(cards.supportsInterface(0x2a55205a));
        // AccessControl
        assertTrue(cards.supportsInterface(0x01ffc9a7));
    }
}

/**
 * @notice Mock ERC-20 for testing
 */
contract MockERC20 {
    string public name;
    string public symbol;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
