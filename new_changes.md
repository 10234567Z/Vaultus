# Vaultus — Planned Changes for Monad Blitz Hackathon

> **Target:** Monad Mainnet (Chain ID 143, 400ms blocks)  
> **Hackathon:** Monad Blitz Hyderabad — Feb 28, 2026 (one-day, 6-hour build)  
> **Goal:** Drop fake pools + Reactive Network, integrate real Monad lending protocols, simplify automation

---

## 1. What Gets Dropped

### Reactive Network (Full Removal)
- **Delete** `contracts/src/ReactiveVault.sol` entirely
- **Remove** `reactive-lib` from `remappings.txt` and `foundry.toml`
- **Remove** `AbstractCallback` inheritance from `AutomationVault.sol`
- **Remove** callback proxy authorization logic (`authorizedSenders`, `onlyCallbackProxy` modifier, etc.)
- **Remove** `reactive-lib/` from `contracts/lib/`

### Fake Pool A / Pool B
- **Delete** `contracts/src/Vault.sol` (simulated lending pool with fake utilization-based APY)
- **Remove** `IVault` interface usage from `AutomationVault.sol`
- **Delete** `contracts/test/Vault.t.sol`

### Current Deployment Artifacts
- Clean out `contracts/broadcast/` (Sepolia + Rootstock + Arbitrum + Polygon + Base deployments — all irrelevant for Monad)

---

## 2. Real Protocol Integration

### Protocol 1: Neverland (Aave v3 Fork)

| Detail | Value |
|--------|-------|
| Type | Aave v3 fork — battle-tested interface |
| Assets | USDC, WMON, WETH, WBTC, USDT0, earnAUSD, gMON |
| Interface | `pool.supply(asset, amount, onBehalfOf, referralCode)` / `pool.withdraw(asset, amount, to)` |

**Key Contracts (Monad Mainnet):**

| Contract | Address |
|----------|---------|
| Pool (Proxy) | `0x8f00661b13cc5f6ccd3885be7b4c9c67545d585` |
| PoolAddressesProvider | `0x49d75170f55c964dfdd6726c74fdede75553a0f` |
| PoolDataProvider | `0xfd0b6b6f736376f7b99ee989c749007c7757fdba` |
| USDC AToken | `0x38648958836ea88b368b4ac23b86ad4b0fe7508` |
| WMON AToken | `0xd0fd2cf7f6ceff4f96b1161f5e995d5843326154` |
| WETH AToken | `0x31f63ae5a96566b93477191778606bebdc4ca6f` |
| WBTC AToken | `0x34c43684293963c546b0a6841008a4d3393b9ab` |
| WrappedTokenGatewayV3 | `0x800409dbd717813bb76501c30e04596cc478f25` |
| UiPoolDataProviderV3 | `0x0733e79171dd5a5e8af41e387c6299bcfe6a7e55` |

### Protocol 2: TownSquare (Monad-Native Lending)

| Detail | Value |
|--------|-------|
| Type | Monad-native lending market |
| TVL | ~$1,032,890 |
| Assets | MON, wMON, USDC (10.1% APY, 80.42% util), USDT (2.42%), WETH, WBTC |

**Key Contracts (Monad Mainnet):**

| Contract | Address |
|----------|---------|
| Hub | `0x2dfdb4bf6c910b5bbbb0d07ec5f088e294628189` |
| USDC Pool | `0xdb4e67f878289a820046f46f6304fd6ee1449281` |
| MON Pool | `0x106d0e2bff74b39d09636bdcd5d4189f24d91433` |
| WMON Pool | `0xf358f9e4ba7d210fde8c9a30522bb0063e15c4bb` |
| SpokeOperations | `0x63cb1cf5accbcc57e0cca047be9673ea5022b8db` |
| SpokeController | `0x8f8a0ed366439576b7db220678ed1259743239e3` |
| PriceFeedManager | `0x428cfa65310c70bc9e65bddb26c65fe4ca490376` |
| LoanController | `0xc4c20efbefa4bde14091a3040d112cf981d8b2db` |
| AccountController | `0xc2df24203ab3a4f3857d649757a99e18de059a16` |
| USDC SpokeToken | `0xa457235b68606a7921b7c525d92e9592e793b4c0` |
| WMON SpokeToken | `0xa2b1ac2bb0a6ad5e74d74f8809a2f935813d273a` |

### Why These Two

| | Neverland | TownSquare |
|---|---|---|
| Model | Aave v3 (well-documented) | Monad-native (hackathon story) |
| Interface | `supply()` / `withdraw()` | `deposit()` / `withdraw()` |
| USDC Support | ✅ | ✅ (highest APY: 10.1%) |
| Hackathon Narrative | "Battle-tested DeFi standard" | "Monad-native innovation" |

**Story:** *"Vaultus automatically allocates between established DeFi (Neverland/Aave) and Monad-native protocols (TownSquare) for optimal yield."*

---

## 3. Automation Architecture (Replacing Reactive Network)

### Problem
Reactive Network handled event-driven rebalancing via cross-chain callbacks. On a single chain (Monad), this is unnecessary complexity.

### Solution: Three-Tier Trigger System

#### Tier 1 — Lazy Rebalancing (Built-in, Zero Infra)
Every `deposit()` and `withdraw()` call checks the APY differential. If it exceeds the threshold, rebalance happens inline. With Monad's 400ms blocks and cheap gas, this costs nothing extra:

```solidity
function deposit(uint256 amount) external nonReentrant {
    // ... share calculation, transfer in ...
    _deployToHigherApyPool(amount);
    _checkAndRebalanceIfNeeded(); // inline APY check
}

function _checkAndRebalanceIfNeeded() internal {
    if (block.timestamp < lastRebalance + minRebalanceInterval) return;
    (uint256 apyA, uint256 apyB) = _fetchCurrentAPYs();
    uint256 diff = apyA > apyB ? apyA - apyB : apyB - apyA;
    if (diff >= rebalanceThreshold) {
        _executeRebalance(apyA, apyB);
    }
}
```

#### Tier 2 — Public `rebalance()` (Permissionless Keeper)
Anyone can call this. The function validates conditions internally — it's a no-op if nothing needs to happen:

```solidity
function rebalance() external nonReentrant {
    require(block.timestamp >= lastRebalance + minRebalanceInterval, "Too soon");
    (uint256 apyA, uint256 apyB) = _fetchCurrentAPYs();
    uint256 diff = apyA > apyB ? apyA - apyB : apyB - apyA;
    require(diff >= rebalanceThreshold, "No rebalance needed");
    _executeRebalance(apyA, apyB);
    emit Rebalanced(apyA, apyB, block.timestamp);
}
```

#### Tier 3 — UI "Rebalance" Button (Demo-Friendly)
A one-click button in the frontend that calls `rebalance()`. Perfect for the live hackathon demo — judges see the rebalancing happen in real time.

### What This Replaces

| Before (Reactive Network) | After (Monad Single-Chain) |
|---|---|
| `Vault.sol` emits `APYUpdated` event | Pool APYs read directly on-chain |
| `ReactiveVault.sol` subscribes to events on Reactive Network | Deleted entirely |
| Cross-chain callback to `AutomationVault.updateAPY()` | Inline check in `deposit()`/`withdraw()` |
| `onlyCallbackProxy` access control | Public `rebalance()` — no access control needed |
| 3 contracts across 2 chains | 1 contract on 1 chain |

---

## 4. New Contract Architecture

### File: `contracts/src/VaultusVault.sol` (New — replaces AutomationVault.sol)

```
VaultusVault.sol
├── State
│   ├── poolNeverland (INeverlandPool) — Aave v3 pool address
│   ├── poolTownSquare (ITownSquarePool) — TownSquare pool address
│   ├── asset (IERC20) — underlying (USDC)
│   ├── totalShares, userShares — share accounting (unchanged)
│   ├── allocationNeverland, allocationTownSquare — tracked allocations
│   ├── rebalanceThreshold — min APY diff to trigger (default 100 bps)
│   └── minRebalanceInterval — cooldown between rebalances
│
├── Core Functions
│   ├── deposit(uint256 amount) → mint shares, deploy to higher-APY pool, lazy rebalance
│   ├── withdraw(uint256 shares) → burn shares, withdraw from pools, return USDC
│   ├── rebalance() → public, permissionless, validated internally
│   └── emergencyWithdraw() → pull everything back, pause
│
├── Internal Logic
│   ├── _fetchCurrentAPYs() → read APY from both protocols
│   ├── _deployToHigherApyPool(amount)
│   ├── _checkAndRebalanceIfNeeded()
│   ├── _executeRebalance(apyA, apyB)
│   └── _withdrawFromPools(amount)
│
├── View Functions
│   ├── getTotalAssets() → sum of both pool balances
│   ├── getUserBalance(address) → shares → asset value
│   ├── getCurrentAPYs() → (neverlandAPY, townSquareAPY)
│   ├── getAllocation() → (neverlandAlloc, townSquareAlloc)
│   └── getSharePrice() → totalAssets / totalShares
│
└── Inherited
    ├── Ownable (OpenZeppelin) — for emergency functions
    ├── ReentrancyGuard (OpenZeppelin)
    └── SafeERC20 (OpenZeppelin)
```

### File: `contracts/src/interfaces/INeverlandPool.sol` (New)

```solidity
interface INeverlandPool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}
```

### File: `contracts/src/interfaces/ITownSquarePool.sol` (New)

```solidity
interface ITownSquarePool {
    function deposit(uint256 amount) external;
    function withdraw(uint256 amount) external;
    // Exact signatures TBD — verify from TownSquare's deployed bytecode/ABI
}
```

---

## 5. Frontend Changes

### `frontend/app/providers.tsx`
- Replace Sepolia chain config with Monad Mainnet:
  ```ts
  const monad = {
    id: 143,
    name: 'Monad',
    nativeCurrency: { name: 'MON', symbol: 'MON', decimals: 18 },
    rpcUrls: {
      default: { http: ['https://rpc.monad.xyz'] },
    },
    blockExplorers: {
      default: { name: 'Monad Explorer', url: 'https://explorer.monad.xyz' },
    },
  }
  ```

### `frontend/app/contracts.ts`
- Replace all ABIs with new `VaultusVault` ABI
- Replace contract addresses with Monad mainnet deployments
- Remove Vault.sol ABI entirely

### `frontend/app/page.tsx`
- Change "Pool A" / "Pool B" labels → "Neverland" / "TownSquare"
- Add "Rebalance" button that calls `rebalance()` on the contract
- Update stats grid to show real protocol names and APYs
- Add protocol logos/icons in the allocation bars
- Update the chain badge from "Sepolia" to "Monad"

---

## 6. Test Changes

### Delete
- `contracts/test/Vault.t.sol` — tests for fake pool, no longer relevant

### Rewrite
- `contracts/test/AutomationVault.t.sol` → `contracts/test/VaultusVault.t.sol`
  - Mock both Neverland (Aave v3 interface) and TownSquare pools
  - Test deposit → funds go to higher-APY pool
  - Test withdraw → funds pulled proportionally
  - Test lazy rebalance triggers on deposit/withdraw
  - Test public `rebalance()` with threshold validation
  - Test emergency withdraw pulls from both pools
  - Test share accounting accuracy

---

## 7. Deploy Script

### `contracts/script/DeployVaultus.s.sol` (Replaces DeployVault.s.sol)

```solidity
// Points to real Monad mainnet addresses
address constant NEVERLAND_POOL = 0x8f00661b13cc5f6ccd3885be7b4c9c67545d585;
address constant TOWNSQUARE_USDC_POOL = 0xdb4e67f878289a820046f46f6304fd6ee1449281;
address constant USDC = ...; // Monad mainnet USDC address

function run() external {
    vm.startBroadcast();
    VaultusVault vault = new VaultusVault(
        USDC,
        NEVERLAND_POOL,
        TOWNSQUARE_USDC_POOL,
        100,  // 1% rebalance threshold
        1 hours // min rebalance interval
    );
    vm.stopBroadcast();
}
```

### Foundry Config Updates (`foundry.toml`)
```toml
[profile.default]
src = "src"
out = "out"
libs = ["lib"]
solc = "0.8.33"

[rpc_endpoints]
monad = "https://rpc.monad.xyz"
```

### Remappings (`remappings.txt`)
```
@openzeppelin/=lib/openzeppelin-contracts/
forge-std/=lib/forge-std/src/
# reactive-lib line REMOVED
```

---

## 8. Monad Network Reference

| Property | Value |
|----------|-------|
| Chain ID | 143 |
| RPC | `https://rpc.monad.xyz` |
| Alt RPCs | `https://rpc1.monad.xyz`, `https://rpc2.monad.xyz` |
| Block Time | 400ms |
| TPS | ~1,440 current |
| Native Token | MON |
| Wrapped MON | `0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |
| Multicall3 | `0xcA11bde05977b3631167028862Be2a173976CA11` |
| USDC (Circle) | TBD — verify from Circle's deployment |

---

## 9. Estimated Build Order (6-Hour Sprint)

| # | Task | Time | Priority |
|---|------|------|----------|
| 1 | Delete ReactiveVault.sol, Vault.sol, strip reactive-lib | 15 min | P0 |
| 2 | Write pool interfaces (INeverlandPool, ITownSquarePool) | 15 min | P0 |
| 3 | Write VaultusVault.sol with share accounting + dual-pool logic | 90 min | P0 |
| 4 | Write tests with mock pools | 45 min | P0 |
| 5 | Update foundry.toml, remappings, deploy script for Monad | 15 min | P0 |
| 6 | Update frontend providers.tsx for Monad chain | 10 min | P0 |
| 7 | Update frontend contracts.ts with new ABI + addresses | 15 min | P0 |
| 8 | Update frontend page.tsx (labels, rebalance button, chain) | 30 min | P1 |
| 9 | Deploy to Monad mainnet | 15 min | P1 |
| 10 | Polish UI, test live, prep demo | 30 min | P2 |
| | **Total** | **~4.5 hrs** | |

Buffer of 1.5 hours for debugging, ABI verification, and unexpected issues.

---

## 10. Other Protocols Considered (Backup)

If Neverland or TownSquare have issues day-of, these are ready alternatives:

| Protocol | Type | Key Contract | Notes |
|----------|------|-------------|-------|
| Curvance | Compound-style cTokens | cUSDC: `0x21adbb60a5fb909e7f1fb48aacc78d6bb399baf88b5` | `mint()`/`redeem()` interface |
| Euler Finance | Modular lending | EVC: `0x7a9324e8f270413fa2e458f5831226d99c7477cd` | Complex but powerful |
| Morpho | Lending optimizer | Morpho: `0xd5d960e8c380b724a48ac59e2dff1b2cb4aeaee` | MetaMorpho vaults available |
| Mellow Protocol | Leveraged farming vaults | Monad Vault: `0x912644cdfada93469b8ab5b4351bdcff61691613` | Yield aggregator |
