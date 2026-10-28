# Mint-to-Liquidity Hook (Uniswap v4)

A generic Uniswap v4 hook that keeps a token's pool price inside the band set by the token's own issuer. Any token that can be minted and redeemed onchain gets a Uniswap market that can never trade above its mint price or below its redemption price. Whenever a swap pushes the price out of the band, the hook mints or redeems through the issuer and trades the price back in the same transaction. The arbitrage profit goes to the protocol instead of to MEV bots.

> Status: **prototype**. It exists to measure how hard the production hook is to build. It is unaudited and not for mainnet use.

## 1. Problem

A new token needs a market, and a market needs liquidity and arbitrageurs to keep it priced. For tokens with an onchain issuer (vaults, liquid staking tokens, bonding-curve tokens), the issuer already knows the right price: what it costs to mint a new token and what a token redeems for. But the issuer and the market don't talk to each other:

1. The issuer sells and redeems at its own prices, in its own contract.
2. The Uniswap pool trades the same token at whatever price its last trade left behind.

Outside arbitrageurs close the gap, when they bother to, and keep the profit. Until they do, buyers overpay and sellers get too little.

### Why Everstrat is the test case

[Everstrat](https://everstrat.xyz) is an ETH yield protocol on Ethereum mainnet. Users deposit ETH and mint EVE, a token backed by the protocol's book, which is **100% Uniswap v3 liquidity**. Everstrat earns its yield by providing liquidity to Uniswap, yet its own token has no reliably priced market. That gap is what this hook closes, for Everstrat and for every issuer-backed token like it.

Everstrat's AMM contract already sets EVE's price band:

- **Ceiling: the premium price.** `AMM.enter` mints EVE at `NAV / (supply × connectorWeight)`.
- **Floor: the base price.** `AMM.exit` redeems EVE at `NAV / supply`.

What the disconnected pool costs, measured on Everstrat:

- **Value leaks to arbitrageurs.** 21 of 38 mints could be arbitraged against the pool right after, by up to 26.6%.
- **Two quotes for one token.** The AMM and the pool price EVE differently, and nothing keeps them aligned.

## 2. Design summary

The pool is an **ordinary concentrated-liquidity pool**: anyone can provide liquidity, and inside the band the price is set by trading as usual. The hook adds no pricing of its own. It reads the band from the issuer and **enforces** it.

```
                  ┌──────────── ceiling = issuer mint price ────────────┐
pool price above  │  hook mints at the ceiling, sells into the pool      │  price pushed down to ceiling
                  │                                                      │
inside the band   │  normal v4 trading, LPs earn fees, hook does nothing │
                  │                                                      │
pool price below  │  hook buys from the pool, redeems at the floor       │  price pushed up to floor
                  └──────────── floor = issuer redemption price ─────────┘
```

- **The issuer is the source of truth.** The hook never computes a price. It trades with the issuer only at the issuer's own quotes and under the issuer's own checks, so it takes on no pricing risk the issuer doesn't already accept.
- **No capital needed.** v4's flash accounting lets the hook swap first and settle with the issuer afterwards, all within one `unlock`.
- **Profit stays with the protocol.** The spread between the pool price and the band edge goes to the issuer's beneficiary address.
- **Generic.** A token plugs in through a small adapter (§4). EVE's adapter wraps Everstrat's AMM.

## 3. Rebalancing

A **rebalance** moves the pool price back to the nearest band edge. It runs:

- in `beforeSwap`, to correct drift since the last trade (the issuer's value moves while the pool sits idle), so the swapper trades in band;
- in `afterSwap`, to correct the swapper's own push past an edge;
- from `rebalance(PoolKey)`, which anyone can call (keeper backstop).

The band is read from the adapter once per transaction and cached in transient storage, so `beforeSwap` and `afterSwap` share a single read.

**Price orientation.** `currency0 = ETH`, `currency1 = token`, so `sqrtPriceX96 = √(tokens per ETH)`. A token price `p` (ETH per token) maps to `√(1/p) × 2⁹⁶`. The ceiling therefore becomes the *lower* sqrtPrice bound and the floor the *upper* one.

### 3.1 Above the ceiling (pool price > mint price `C`)

1. The hook swaps token → ETH in the pool, with `sqrtPriceLimitX96` at `C`. The swap stops exactly at the ceiling and leaves the hook owing `t` tokens and owed `e` ETH.
2. `take` ETH `e` from the PoolManager.
3. `adapter.mint{value: ⌈t × C⌉}()` returns at least `t` tokens.
4. `sync` → transfer `t` tokens to the PoolManager → `settle`.
5. Profit `e − ⌈t × C⌉` (> 0, because every unit sold above `C`) and any token dust go to the beneficiary.

### 3.2 Below the floor (pool price < redemption price `F`)

1. The hook swaps ETH → token, exact output, with `sqrtPriceLimitX96` at `F`. The output is capped at `adapter.maxRedeemNow() / F`, so the redemption can always be paid out immediately.
2. `take` the `t` tokens bought.
3. `adapter.redeem(t)` returns `⌊t × F⌋` ETH.
4. `settle{value: e}` for the ETH owed to the pool.
5. Profit `⌊t × F⌋ − e` goes to the beneficiary.

Beyond the issuer's immediate exit capacity the floor is **soft**: the hook moves the price as far as that capacity allows and stops.

### 3.3 Never blocking a swap

The rebalance runs as an external self-call, `try this.rebalanceInternal(key) {} catch {}`. If the issuer reverts (paused, unhealthy, caps reached), the whole rebalance unwinds, including its pool swap, and the user's swap goes through as if the hook weren't there. The PoolManager never calls a hook for swaps the hook makes itself, so the rebalance swap can't recurse.

## 4. Issuer adapter

A token plugs in by deploying an adapter. The hook only ever talks to the adapter.

```solidity
interface IIssuerAdapter {
    function token() external view returns (IERC20);
    function mintPrice() external view returns (uint256 _ceiling);        // ETH per token, WAD
    function redeemPrice() external view returns (uint256 _floor);        // ETH per token, WAD; 0 = no floor
    function maxRedeemNow() external view returns (uint256 _ethOut);      // immediate exit capacity
    function mint(uint256 _minTokens) external payable returns (uint256 _tokensOut);
    function redeem(uint256 _tokens, uint256 _minETH) external returns (uint256 _ethOut);
    function beneficiary() external view returns (address);
}
```

A token with mint but no redemption (such as a mint-only bonding curve) returns `redeemPrice() = 0` and gets a ceiling only.

**The anchor rule:** the adapter's prices must never read the pool this hook guards.

### 4.1 Everstrat adapter

| Adapter call | Everstrat AMM |
| --- | --- |
| `mintPrice()` | `evePremiumPriceInETH()` |
| `redeemPrice()` | `eveBasePriceInETH()` |
| `maxRedeemNow()` | `freeBalance()` |
| `mint` | `enter{value}(_minTokens)` |
| `redeem` | `exit(ethOut, _tokens, tolerance)`; reverts if it returns a non-zero `batchId` (a queued exit) |

Setup on the Everstrat side, through the 48h timelock:

- whitelist the adapter (`AMM.enter` checks `msg.sender`);
- no new roles are needed. The adapter is an ordinary AMM user, and it approves the AMM so `burnFrom` can pull its EVE.

## 5. Contracts

Following the `everstrat-xyz/contracts` conventions (interfaces hold events, errors and structs; errors are prefixed with the contract name; `_camelCase` arguments; named imports).

| File | Role |
| --- | --- |
| `src/MintToLiquidityHook.sol` | Pool registration, band reads, rebalance, profit sweep |
| `src/libraries/BandMath.sol` | Price ↔ sqrtPriceX96 conversion and rounding, fuzzed in isolation |
| `src/interfaces/IIssuerAdapter.sol` | What an issuer implements (§4) |
| `src/interfaces/IMintToLiquidityHook.sol` | Hook structs, events and errors |
| `src/adapters/EverstratAMMAdapter.sol` | §4.1 |
| `test/mocks/MockIssuer.sol` | Reference issuer with a premium-over-NAV mint and a NAV redeem |

The hook extends OpenZeppelin's audited `BaseHook` (`OpenZeppelin/uniswap-hooks` v1.2.1) on `v4-core`, and is compiled with solc `0.8.26` (PoolManager's pinned version).

### 5.1 Hook permissions

| Callback | Enabled | Why |
| --- | --- | --- |
| `beforeInitialize` | yes | Only pools registered with an adapter, with `currency0` = native ETH and `currency1` = `adapter.token()` |
| `beforeSwap` | yes | Rebalance drift before the user trades |
| `afterSwap` | yes | Rebalance the user's push past an edge |
| everything else | no | Liquidity is permissionless; LP fees are normal v4 fees |

### 5.2 Pool registration

`registerPool(IIssuerAdapter _adapter, uint24 _fee, int24 _tickSpacing, uint160 _sqrtPriceX96)` binds the pool to its adapter and initialises it. Only the adapter's owner can call it, so nobody can attach an issuer to a pool the issuer didn't authorise. The starting price must be inside the band.

## 6. Safety rails

| Rail | Behaviour |
| --- | --- |
| Issuer failure | Rebalance is skipped and the user's swap proceeds (§3.3) |
| Queued exit | The adapter reverts, so the rebalance is skipped; the hook never holds a queue position |
| Exit capacity | Floor buys are capped at `maxRedeemNow()` |
| Invalid band | `mintPrice() == 0` or `redeemPrice() > mintPrice()` → rebalance skipped, event emitted |
| Leftover balances | Hook ends every transaction holding no ETH or tokens; profit and dust are swept to `beneficiary()` |
| Foreign pools | `beforeInitialize` reverts for unregistered keys |

## 7. Invariants (Foundry)

1. After a rebalance that ran, the pool price is inside `[floor, ceiling]` (one-tick tolerance), or at the floor-side capacity limit.
2. A rebalance never loses money: profit ≥ 0 in ETH.
3. The hook holds no ETH or tokens between transactions.
4. The hook never causes a queued exit.
5. No user swap reverts because of the hook.
6. The issuer's redemption price per token never decreases as a result of a rebalance (mints happen at the ceiling, burns at the floor).

## 8. Prototype scope

**In:** the hook, `BandMath`, the adapter interface, `MockIssuer`, unit tests for every branch, fuzz tests for `BandMath`, invariant tests (§7), and a mainnet-fork test of `EverstratAMMAdapter` against the deployed AMM.

**Out (production work):**

- Gas profiling and a cheaper trigger, e.g. skipping the issuer read when the pool price is well inside the last known band
- Rebating the out-of-band surplus to the swapper (`afterSwapReturnDelta`) instead of the protocol
- An ERC-4626 adapter
- Router and aggregator integration, audit

## 9. Development

```bash
forge build
forge test
forge fmt --check src/ test/
```

## 10. Open questions

- **Where Everstrat's profit goes.** To the Controller (it accrues to NAV for every holder) or to the AMM (it adds immediate exit capacity)?
- **Rebate or keep.** The swapper who pushes past an edge overpays for that portion. Should the hook keep the surplus, or refund it so the swapper gets the price they would have got by splitting the order with the issuer?
- **Existing liquidity.** EVE's current pool keeps being arbitraged by bots. Does liquidity migrate to the hooked pool, or should both exist?
- **Gas per swap.** Reading Everstrat's NAV is expensive. How much does that cost the pool in routing?

## License

MIT
