# Clash Onchain Smart Contracts

Smart contracts for Clash Onchain NFT + $CLASH economy on Base mainnet.

## Contracts

### `ClashCards.sol` (ERC-1155 NFT)
- 120 unique token IDs (12 card types × 10 levels)
- Token ID encoding: `(card_type_id × 10) + (level - 1)` = 0-119
- 5% royalty via ERC-2981
- AccessControl: `MINTER_ROLE`, `BURNER_ROLE`
- `ERC1155Supply` for total supply tracking
- Base URI: `https://ktrwdkrxsttdadqvudco.supabase.co/storage/v1/object/public/nft-assets/metadata/`

### `ClashCardManager.sol` (Orchestrator)
- Atomic $CLASH + NFT operations
- Functions:
  - `upgradeCard(UpgradeRequest, signature)` - burn 5 L1 → 1 L2
  - `buyPack(PackRequest, signature, tokenIds[], amounts[])` - random cards
  - `buyChest(ChestRequest, signature, tokenIds[], amounts[])` - chest contents as NFTs
- ReentrancyGuard
- Server signature verification
- Replay protection (`usedOperations` mapping)

## Deployment (Base mainnet)

### Prerequisites
- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Deployer wallet with ~0.005 ETH for gas
- BaseScan API key (optional, for verification)

### Step 1: Install dependencies
```bash
forge install
```

### Step 2: Set environment variables
```bash
export PRIVATE_KEY=0x...                    # deployer private key
export CLASH_TOKEN_ADDRESS=0xf3C66dc3afF9d04CbCEAfA8f9dE762a39EE0BBA3  # $CLASH ERC-20
export TREASURY_ADDRESS=0x...               # treasury wallet
export ROYALTY_RECEIVER=0x...               # royalty receiver
export ADMIN_ADDRESS=0x...                  # admin (multisig recommended)
export BASESCAN_API_KEY=...                 # optional, for verification
```

### Step 3: Deploy + verify
```bash
forge script script/Deploy.s.sol:Deploy \
  --rpc-url https://mainnet.base.org \
  --broadcast \
  --verify \
  -vvvv
```

### Step 4: Save deployment addresses
After deployment, save the contract addresses:
```
CLASH_CARDS_ADDRESS=0x...           # ERC-1155 NFT
CLASH_CARD_MANAGER_ADDRESS=0x...    # Manager contract
```

Update these in:
- Frontend (`.env`)
- Edge function env vars
- Game server config

## Testing

```bash
forge test
```

Expected output: 8/8 tests passing.

## Security notes

⚠️ **No third-party audit yet** (deferred per user decision).

Built-in protections:
- ✅ OpenZeppelin libraries (audited base)
- ✅ ReentrancyGuard
- ✅ AccessControl (3 roles)
- ✅ ERC-2981 royalty enforcement
- ✅ Replay protection
- ✅ Server signature verification
- ✅ Deadline check (anti-stale)

Defense-in-depth in edge functions:
- Pre-balance snapshot (anti-race)
- Post-confirmation verify (anti-revert)
- 3-block confirmation wait
- EIP-712 typed data signing (off-chain)

## Architecture

```
$CLASH (ERC-20)             ClashCards (ERC-1155)
  Existing: 0xf3C66...  ←→  NEW: NFT cards (tokenId 0-119)
       ↑                          ↑
       │      ┌───────────────────┘
       │      │
       └──────┴──────→ ClashCardManager (orchestrator)
                       - upgradeCard
                       - buyPack
                       - buyChest
```

## Gas estimates (Base mainnet)

- Deploy ClashCards: ~0.003 ETH
- Deploy ClashCardManager: ~0.002 ETH
- Upgrade card: ~0.0001 ETH
- Buy pack (5 cards): ~0.0002 ETH
- Buy chest (20 cards): ~0.0005 ETH
