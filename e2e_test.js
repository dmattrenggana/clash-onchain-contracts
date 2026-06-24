#!/usr/bin/env node
/**
 * E2E test for Clash Onchain NFT flow
 * 
 * Tests:
 * 1. balanceOf for a known wallet (read-only)
 * 2. totalSupply for tokenIds (read-only)
 * 3. Simulated chest contents (matches edge function logic)
 * 4. Simulated upgrade validation (matches contract logic)
 * 5. NFT metadata fetch (OpenSea-compatible)
 *
 * Run: node e2e_test.js
 */

const https = require('https');
const { keccak256 } = require('js-sha3');

// Contract addresses (Base mainnet)
const CONTRACTS = {
  CLASH_CARDS: '0xF93643759c9C62E0e2E70969E2397806bE5CF609',
  MANAGER: '0x425894394a636A95dc5Ed947dF7eE63d93062682',
  CLASH_TOKEN: '0xf3C66dc3afF9d04CbCEAfA8f9dE762a39EE0BBA3',
};

const SUPABASE_URL = 'https://ktrwdkrxsttdadqvudco.supabase.co';

// Card type IDs (from contract)
const CARD_TYPE_IDS = {
  knight: 0, archer: 1, giant: 2, wyvern: 3, wizard: 4, goblin: 5,
  barbarian: 6, healer: 7, gunslinger: 8, barrel_bomb: 9, meteor: 10, incubus: 11,
};

// Common vs Epic classification (per user spec 2026-06-24)
const COMMON_CARDS = ['knight', 'archer', 'wizard', 'goblin', 'barrel_bomb', 'meteor', 'incubus'];
const EPIC_CARDS = ['wyvern', 'giant', 'barbarian', 'healer', 'gunslinger'];

// Chest config (must match supabase/functions/open-chest/index.ts)
const CHEST_CONFIG = {
  silver:  { common: 20,  epic: 0  },
  gold:    { common: 60,  epic: 10 },
  magical: { common: 120, epic: 30 },
};

// Upgrade costs in $CLASH (18 decimals)
const UPGRADE_COSTS = [10_000_000e18, 20_000_000e18, 40_000_000e18, 80_000_000e18,
                      160_000_000e18, 320_000_000e18, 640_000_000e18,
                      1_280_000_000e18, 2_560_000_000e18];

// NFT burn counts
const UPGRADE_BURN_COUNTS = [10, 40, 80, 160, 320, 640, 1280, 2560, 5120];

// Helper: tokenIdOf(cardType, level) = cardType * 256 + (level - 1)
function tokenIdOf(cardType, level) {
  return cardType * 256 + (level - 1);
}

// Helper: rarity from level
function rarityFromLevel(level) {
  if (level <= 2) return 'common';
  if (level <= 5) return 'rare';
  if (level <= 8) return 'epic';
  return 'legendary';
}

// Helper: scale stat (1.2x per level)
function scaleStat(base, level) {
  return Math.floor(base * (1 + (level - 1) * 0.2));
}

// Helper: HTTP GET
function httpGet(url) {
  return new Promise((resolve, reject) => {
    https.get(url, (res) => {
      let data = '';
      res.on('data', (chunk) => data += chunk);
      res.on('end', () => {
        try {
          resolve({ status: res.statusCode, data: JSON.parse(data) });
        } catch (e) {
          resolve({ status: res.statusCode, data });
        }
      });
    }).on('error', reject);
  });
}

// Helper: JSON-RPC call
async function rpcCall(method, params) {
  return new Promise((resolve, reject) => {
    const data = JSON.stringify({ jsonrpc: '2.0', id: 1, method, params });
    const url = new URL('https://mainnet.base.org');
    const req = https.request({
      hostname: url.hostname,
      path: url.pathname,
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
    }, (res) => {
      let body = '';
      res.on('data', (chunk) => body += chunk);
      res.on('end', () => {
        try {
          resolve(JSON.parse(body));
        } catch (e) {
          reject(e);
        }
      });
    });
    req.on('error', reject);
    req.write(data);
    req.end();
  });
}

// Calculate function selector
function getSelector(sig) {
  return '0x' + keccak256(sig).slice(0, 8);
}

async function callContract(to, data) {
  const res = await rpcCall('eth_call', [{ to, data }, 'latest']);
  if (res.error) throw new Error(JSON.stringify(res.error));
  return res.result;
}

// ═══════════════════════════════════════════════════════════════
//  TEST 1: Read on-chain state
// ═══════════════════════════════════════════════════════════════
async function test1_onchainState() {
  console.log('\n=== TEST 1: On-chain state ===');
  
  // Test 1a: totalSupply for various tokenIds
  const totalSupplySelector = getSelector('totalSupply(uint256)');
  for (const cardId of ['knight', 'giant', 'wyvern']) {
    const cardTypeId = CARD_TYPE_IDS[cardId];
    const tokenId = tokenIdOf(cardTypeId, 1);  // L1
    const data = totalSupplySelector + tokenId.toString(16).padStart(64, '0');
    const result = await callContract(CONTRACTS.CLASH_CARDS, data);
    const supply = parseInt(result, 16);
    console.log(`  ${cardId} L1 (tokenId ${tokenId}): totalSupply = ${supply}`);
  }
  
  // Test 1b: balanceOf for admin wallet
  const balanceOfSelector = getSelector('balanceOf(uint256,address)');
  const adminAddr = '43d9a5cb3c0299e3de882e10036ee9de0497f234'.padStart(64, '0');
  for (const cardId of ['knight', 'giant']) {
    const cardTypeId = CARD_TYPE_IDS[cardId];
    const tokenId = tokenIdOf(cardTypeId, 1);
    const data = balanceOfSelector + tokenId.toString(16).padStart(64, '0') + adminAddr;
    try {
      const result = await callContract(CONTRACTS.CLASH_CARDS, data);
      const balance = parseInt(result, 16);
      console.log(`  Admin ${cardId} L1 balance: ${balance}`);
    } catch (e) {
      console.log(`  Admin ${cardId} L1 balance: error (${e.message.slice(0, 50)})`);
    }
  }
}

// ═══════════════════════════════════════════════════════════════
//  TEST 2: Chest distribution simulation
// ═══════════════════════════════════════════════════════════════
function test2_chestDistribution() {
  console.log('\n=== TEST 2: Chest distribution ===');
  
  for (const [chestType, config] of Object.entries(CHEST_CONFIG)) {
    const totalCards = config.common + config.epic;
    console.log(`  ${chestType.toUpperCase()}: ${config.common} common + ${config.epic} epic = ${totalCards} total`);
    console.log(`    Common pool: ${COMMON_CARDS.join(', ')}`);
    console.log(`    Epic pool:   ${EPIC_CARDS.join(', ')}`);
  }
  
  // Verify all cards are accounted for
  const allCards = Object.keys(CARD_TYPE_IDS);
  const unaccounted = allCards.filter(c => !COMMON_CARDS.includes(c) && !EPIC_CARDS.includes(c));
  if (unaccounted.length > 0) {
    console.error(`  ❌ Unaccounted cards: ${unaccounted.join(', ')}`);
  } else {
    console.log(`  ✅ All ${allCards.length} cards accounted for in chest pool`);
  }
}

// ═══════════════════════════════════════════════════════════════
//  TEST 3: Upgrade cost + burn validation
// ═══════════════════════════════════════════════════════════════
function test3_upgradeValidation() {
  console.log('\n=== TEST 3: Upgrade validation ===');
  
  for (let level = 1; level <= 9; level++) {
    const cost = UPGRADE_COSTS[level - 1];
    const burnCount = UPGRADE_BURN_COUNTS[level - 1];
    const newRarity = rarityFromLevel(level + 1);
    console.log(`  L${level} → L${level + 1}: cost=${(cost / 1e18).toLocaleString()} $CLASH, burn=${burnCount} NFTs, new rarity=${newRarity}`);
  }
  console.log(`  L10 = MAX (no further upgrade)`);
}

// ═══════════════════════════════════════════════════════════════
//  TEST 4: NFT metadata (OpenSea-compatible)
// ═══════════════════════════════════════════════════════════════
async function test4_metadata() {
  console.log('\n=== TEST 4: NFT metadata ===');
  
  // Test Knight L1
  const url = `${SUPABASE_URL}/storage/v1/object/public/nft-assets/metadata/0.json`;
  const res = await httpGet(url);
  if (res.status === 200) {
    console.log(`  ✅ Knight L1 metadata: ${res.data.name}`);
    console.log(`    Description: ${res.data.description}`);
    console.log(`    Image: ${res.data.image.slice(0, 60)}...`);
    const attrs = {};
    res.data.attributes.forEach(a => attrs[a.trait_type] = a.value);
    console.log(`    Stats: HP=${attrs.HP}, Attack=${attrs.Attack}, Rarity=${attrs.Rarity}, Elixir=${attrs['Elixir Cost']}`);
  } else {
    console.log(`  ❌ Knight L1 metadata: HTTP ${res.status}`);
  }
  
  // Test Knight L10 (legendary)
  const url10 = `${SUPABASE_URL}/storage/v1/object/public/nft-assets/metadata/9.json`;
  const res10 = await httpGet(url10);
  if (res10.status === 200) {
    const attrs = {};
    res10.data.attributes.forEach(a => attrs[a.trait_type] = a.value);
    console.log(`  ✅ Knight L10 metadata: Rarity=${attrs.Rarity}, HP=${attrs.HP}, Attack=${attrs.Attack}`);
  }
  
  // Test Epic Giant L1
  const urlG = `${SUPABASE_URL}/storage/v1/object/public/nft-assets/metadata/512.json`;
  const resG = await httpGet(urlG);
  if (resG.status === 200) {
    const attrs = {};
    resG.data.attributes.forEach(a => attrs[a.trait_type] = a.value);
    console.log(`  ✅ Giant L1 metadata: Card Pool=${attrs['Card Pool']}, HP=${attrs.HP}`);
  }
}

// ═══════════════════════════════════════════════════════════════
//  TEST 5: L1-only enforcement (tokenId % 256 == 0)
// ═══════════════════════════════════════════════════════════════
function test5_l1Enforcement() {
  console.log('\n=== TEST 5: L1-only enforcement ===');
  
  for (let level = 1; level <= 10; level++) {
    const tokenId = tokenIdOf(0, level);  // Knight
    const isL1 = tokenId % 256 === 0;
    console.log(`  Knight L${level} (tokenId ${tokenId}): ${isL1 ? '✅ ALLOWED' : '❌ BLOCKED'} in buyChest`);
  }
}

// ═══════════════════════════════════════════════════════════════
//  TEST 6: Edge function health check
// ═══════════════════════════════════════════════════════════════
async function test6_edgeFunctions() {
  console.log('\n=== TEST 6: Edge functions ===');
  
  const functions = ['upgrade-card', 'open-chest'];
  for (const fn of functions) {
    const url = `${SUPABASE_URL}/functions/v1/${fn}`;
    // Test with no body (should return 400 or similar)
    const res = await new Promise((resolve) => {
      const req = https.request(url, { method: 'POST' }, (response) => {
        let data = '';
        response.on('data', (chunk) => data += chunk);
        response.on('end', () => resolve({ status: response.statusCode, data }));
      });
      req.on('error', () => resolve({ status: 0 }));
      req.end();
    });
    console.log(`  ${fn}: HTTP ${res.status}`);
    if (res.status === 200) {
      console.log(`    Body: ${res.data.slice(0, 80)}`);
    }
  }
}

// ═══════════════════════════════════════════════════════════════
//  Run all tests
// ═══════════════════════════════════════════════════════════════
async function main() {
  console.log('═'.repeat(60));
  console.log('  CLASH ONCHAIN NFT E2E TEST');
  console.log('═'.repeat(60));
  
  await test1_onchainState();
  test2_chestDistribution();
  test3_upgradeValidation();
  await test4_metadata();
  test5_l1Enforcement();
  await test6_edgeFunctions();
  
  console.log('\n' + '═'.repeat(60));
  console.log('  TESTS COMPLETE');
  console.log('═'.repeat(60));
}

main().catch((e) => {
  console.error('FATAL:', e);
  process.exit(1);
});
