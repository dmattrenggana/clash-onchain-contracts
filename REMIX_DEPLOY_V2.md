# Remix Deployment Guide v2 (Clean Self-Contained)

Deploy Clash Onchain NFT + $CLASH contracts via Remix. **No npm install, no Foundry, no external dependencies, no special compiler flags.**

## Step 1: Setup Remix

1. Buka https://remix.ethereum.org
2. **File Explorer** tab → **New File** → name: `Clash.sol`
3. Paste isi `ClashOnchain_Remix.sol`

## Step 2: Compile

1. **Solidity Compiler** tab
2. Version: **0.8.20**
3. Default settings (optimizer enabled is fine)
4. Klik **"Compile Clash.sol"**

Should see green checkmark, no errors.

## Step 3: Connect MetaMask ke Base

1. **Settings** → **Networks** → **Add Network**
2. Network: `Base`
3. RPC: `https://mainnet.base.org`
4. Chain ID: `8453`
5. Currency: ETH
6. Block Explorer: https://basescan.org

Make sure deployer wallet punya ~0.01 ETH di Base.

## Step 4: Deploy ClashCards (NFT contract)

1. **Deploy & Run** tab
2. **Environment**: `Injected Provider - MetaMask`
3. **Contract**: pilih `ClashCards`
4. Constructor args:
   - `baseURI` (string): `https://ktrwdkrxsttdadqvudco.supabase.co/storage/v1/object/public/nft-assets/metadata/`
   - `royaltyReceiver_` (address): **wallet lo (multisig recommended)**
   - `admin_` (address): **wallet lo (multisig recommended)**
5. Klik **"Deploy"** → confirm di MetaMask
6. **Copy contract address** → save di notepad

## Step 5: Deploy ClashCardManager

1. **Contract**: pilih `ClashCardManager`
2. Constructor args:
   - `clashToken_` (address): `0xf3C66dc3afF9d04CbCEAfA8f9dE762a39EE0BBA3` (existing $CLASH)
   - `clashCards_` (address): **address dari Step 4**
   - `treasury_` (address): **wallet lo (treasury)**
   - `admin_` (address): **wallet lo (sama dengan ClashCards admin)**
3. Klik **"Deploy"** → confirm di MetaMask
4. **Copy contract address** → save di notepad

## Step 6: Grant roles (Remix console)

Di Remix, klik icon terminal (bawah) untuk buka console. Paste:

```javascript
// Connect ke ClashCards
const cards = await ethers.getContractAt("ClashCards", "0x...CLASHCARDS_ADDRESS...");
const manager = "0x...MANAGER_ADDRESS...";

// Grant MINTER_ROLE
const MINTER_ROLE = ethers.id("MINTER_ROLE");
let tx = await cards.grantRole(MINTER_ROLE, manager);
await tx.wait();
console.log("MINTER_ROLE granted");

// Grant BURNER_ROLE
const BURNER_ROLE = ethers.id("BURNER_ROLE");
tx = await cards.grantRole(BURNER_ROLE, manager);
await tx.wait();
console.log("BURNER_ROLE granted");

// Verify
console.log("MINTER:", await cards.hasRole(MINTER_ROLE, manager));
console.log("BURNER:", await cards.hasRole(BURNER_ROLE, manager));
```

## Step 7: Verify on BaseScan

- Tunggu 1-2 menit
- Cek https://basescan.org/address/0x...CLASHCARDS...
- Cek https://basescan.org/address/0x...MANAGER...

## Step 8: Save addresses

Simpan di file `.env`:
```
CLASH_CARDS_ADDRESS=0x...
CLASH_CARD_MANAGER_ADDRESS=0x...
```

## Constructor Parameters Cheat Sheet

| Contract | Parameter | Value |
|---|---|---|
| ClashCards | `baseURI` | `https://ktrwdkrxsttdadqvudco.supabase.co/storage/v1/object/public/nft-assets/metadata/` |
| ClashCards | `royaltyReceiver_` | Your wallet (multisig) |
| ClashCards | `admin_` | Your wallet (multisig, can be same) |
| ClashCardManager | `clashToken_` | `0xf3C66dc3afF9d04CbCEAfA8f9dE762a39EE0BBA3` |
| ClashCardManager | `clashCards_` | ClashCards address (from Step 4) |
| ClashCardManager | `treasury_` | Your wallet (treasury) |
| ClashCardManager | `admin_` | Same as ClashCards admin |

## Cost Estimate (Base mainnet)

- Deploy ClashCards: ~0.003 ETH (~$6-9)
- Deploy ClashCardManager: ~0.002 ETH (~$4-6)
- Grant roles (2 txns): ~0.0001 ETH (~$0.30)
- **Total**: ~0.005 ETH (~$10-15)

## What You Get

- ✅ 12 initial card types (Knight, Archer, ..., Incubus) × 10 levels
- ✅ Token ID encoding: `(cardType × 256) + (level - 1)`
- ✅ Initial 120 unique NFTs (IDs 0-9, 256-265, ..., 2815-2824)
- ✅ 5% royalty on all secondary sales
- ✅ Atomic upgrade: burn NFTs + take $CLASH + mint new NFT
- ✅ Atomic chest: take $CLASH + mint NFT batch
- ✅ ReentrancyGuard
- ✅ EIP-712 server signatures
- ✅ Replay protection
- ✅ Admin flexibility:
  - `addCardType()`: tambah card type baru
  - `setMaxLevel()`: naikin max level
  - `setUpgradeCost()`: adjust pricing
  - `setChestCost()`: adjust chest pricing
  - `setPackCost()`: set pack pricing (untuk nanti)
  - `setTreasury()`: pindahin $CLASH revenue
  - `setGameServer()`: tambah/hapus game server

## Troubleshooting

### "Stack too deep" error
- This is fixed in v2 — contract refactored to avoid stack-too-deep
- Make sure you're using the latest `ClashOnchain_Remix.sol`
- Use Solidity **0.8.20** (not newer)

### Cannot find via-ir setting
- v2 doesn't need via-ir — just use default settings
- Contract is refactored to compile without it

### "Compiler error"
- Make sure you selected via-ir
- Try clearing Remix cache: File Explorer → ⋮ → Clear Local Storage

### "Insufficient funds"
- Deployer wallet needs ~0.01 ETH on Base
- Bridge from mainnet: https://bridge.base.org

### "Transaction failed"
- Check gas limit in MetaMask
- Try again with higher gas

### "Wrong constructor argument"
- Check parameter order (cheat sheet above)
- For address: must be 0x... format, no quotes
- For string: must be in quotes

## Next Steps

1. ✅ Deploy both contracts (this guide)
2. ✅ Grant roles (Step 6)
3. Save addresses for edge function env vars
4. Test with internal wallet (small amount)
5. Update edge functions to call manager.upgradeCard / buyChest
6. Update frontend with new NFT flow

---

**Ready to deploy?** Open https://remix.ethereum.org dan mulai dari Step 1.
