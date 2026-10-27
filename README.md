# Mint-to-Liquidity Hook (Uniswap v4)

A generic Uniswap v4 hook that gives any **mintable token** automated liquidity in one step. A swap against the pool mints or burns the token at its issuer-reported fair value plus a risk-priced spread, and the proceeds become the pool's exit liquidity in the same transaction. No one has to seed the pool, run a market maker or keep ranges in place.

> Status: **prototype**. It exists to measure how hard the production hook is to build. It is unaudited and not for mainnet use.

## 1. Problem

Today, minting a token and providing its liquidity are two separate steps, done by different people in different contracts:

1. A user deposits into the issuer's contract to mint.
2. Someone else approves and deposits that token plus a paired asset into an AMM pool.

### Why Everstrat is the test case

[Everstrat](https://everstrat.xyz) is an ETH yield protocol on Ethereum mainnet, live since 1 Sep 2026. Users deposit ETH and mint EVE, a reserve-backed token whose value is a share of the protocol's book. The book is **100% Uniswap liquidity**: every strategy is a concentrated-liquidity position on a Uniswap v3 pool (WETH/USDC, WETH/USDT, UNI/WETH), marked on a 30-minute TWAP plus Chainlink. So Everstrat earns its yield by providing liquidity to Uniswap, yet its own token has no reliable liquidity. That gap is exactly what this hook closes, for Everstrat and for every vault-style token with the same shape.

It is small (about 5.2 ETH of fair value), but it gives this prototype what a whitepaper can't: a live, on-chain fair value, a real mint/burn token, and measured data on what the two-step model costs.

Consequences, measured on Everstrat's live book:

- **Price drift leaks value.** The pool price wanders from the mint price; 21 of 38 entries were arbitrageable right after mint (typically +2–6%, up to +26.6%).
- **A fixed premium decays.** The pool premium over NAV fell from +20.6% to +0.41%.
- **Idle capital.** Minted ETH waits for a keeper to deploy it, and the keeper only fires above 0.1 ETH.
- **Two quotes, one token.** A direct mint/burn path and a pool path quote the same token differently, which is an arbitrage the issuer creates itself.

## 2. Design summary

The pool is the **venue**; the hook is the **quoter**. The hook takes over pricing in `beforeSwap` and returns a delta, so the v4 concentrated-liquidity curve is never used (custom-curve pattern).

```
swapper ──swap──▶ PoolManager ──beforeSwap──▶ MintToLiquidityHook ──reads──▶ issuer.fairValuePerToken()
                                                      │
                               buy:  mint token ◀─────┤─────▶ keep ETH as exit reserve, excess → treasury
                               sell: burn token ◀─────┘─────▶ pay ETH from the exit reserve
```

- **Buy (ETH → token):** the hook takes the ETH, mints `amount` tokens straight into the PoolManager and settles them. The ETH stays in the hook up to the pool's target reserve; anything above it is flushable to the issuer's treasury.
- **Sell (token → ETH):** the hook takes the tokens, burns them, and pays ETH out of the reserve.
- **One step:** issuance, pricing and exit liquidity all happen in the swap transaction. There's no approval of the token to a pool, no idle mint window and no LP management.

## 3. Pricing

All prices are in ETH per token, 18-decimal fixed point (`WAD`). `F` = fair value per token from the issuer.

```
ask = F × (1 + askSpread)          buy price  (rounded up)
bid = F × (1 − bidSpread)          sell price (rounded down)
```

**Self-rebalancing bid.** The bid widens as the exit reserve falls below its target, so a drained reserve makes exits more expensive and new buys refill it. That makes the quote arbitrage-consistent only at the target composition, so arbitrageurs, not keepers, pay to restore it (the Curve Yield Basis idea, applied to composition rather than leverage).

```
target     = targetReserveBps × F × supply           (ETH)
deficit    = max(0, target − reserve) / target        (0 … 1, WAD)
bidSpread  = min(baseBidBps + skewBps × deficit, maxSpreadBps)
askSpread  = baseAskBps
```

**Amounts** (both directions, exact-input and exact-output; rounding always favours the protocol):

| Direction | Specified | Unspecified |
| --- | --- | --- |
| Buy, exact input | ETH in `e` | tokens out = ⌊e × WAD / ask⌋ |
| Buy, exact output | tokens out `t` | ETH in = ⌈t × ask / WAD⌉ |
| Sell, exact input | tokens in `t` | ETH out = ⌊t × bid / WAD⌋ |
| Sell, exact output | ETH out `e` | tokens in = ⌈e × WAD / bid⌉ |

Every buy fills at or above `F` and every sell at or below `F`, so **no hook trade can lower fair value per token** (the core invariant, §7).

## 4. Issuer interface

A token plugs in by implementing `IMintableToken` and granting the hook its mint and burn rights. Nothing else is needed.

```solidity
interface IMintableToken is IERC20 {
    function mint(address _to, uint256 _amount) external;                // hook-only
    function burn(address _from, uint256 _amount) external;              // hook-only
    function fairValuePerToken() external view returns (uint256 _valueInETH, uint256 _updatedAt);
    function mintCapRemaining() external view returns (uint256);
    function paused() external view returns (bool);
    function treasury() external view returns (address);
    function issuerAdmin() external view returns (address);
}
```

**The anchor rule:** `fairValuePerToken()` must be a valuation computed from external market data that never includes the token itself, and it must never read this pool. The hook's ETH reserve is part of the issuer's backing and should be counted in its fair value (`hook.ethBalanceOf(poolId)`).

## 5. Contracts

Three contracts and two interfaces, following the `everstrat-xyz/contracts` conventions (interfaces hold events, errors and structs; errors are prefixed with the contract name; `_camelCase` arguments; named imports).

| File | Role |
| --- | --- |
| `src/MintToLiquidityHook.sol` | The hook: pool registration, quote, settlement, reserve accounting |
| `src/libraries/MintToLiquidityMath.sol` | Pure pricing math (spreads, skew, four amount formulas), fuzzed in isolation |
| `src/interfaces/IMintableToken.sol` | What an issuer implements (§4) |
| `src/interfaces/IMintToLiquidityHook.sol` | Hook structs, events and errors |
| `test/mocks/MockMintableToken.sol` | Reference issuer: fair value = (treasury ETH + hook reserve) / supply |

The hook extends OpenZeppelin's audited `BaseHook` (`OpenZeppelin/uniswap-hooks` v1.2.1) on `v4-core`, and is compiled with solc `0.8.26` (PoolManager's pinned version).

### 5.1 Hook permissions

| Callback | Enabled | Why |
| --- | --- | --- |
| `beforeInitialize` | yes | Only the hook itself may initialise its pools (sender == hook), with currency0 = native ETH and a registered config |
| `beforeAddLiquidity` | yes | Reverts: no third-party AMM liquidity; the hook is the only market maker |
| `beforeSwap` + `beforeSwapReturnDelta` | yes | Custom curve: the hook prices and settles every swap |
| everything else | no | |

### 5.2 Pool registration

`registerPool(IMintableToken _token, int24 _tickSpacing, PoolConfig _config)`, callable only by `_token.issuerAdmin()`. It validates the config, stores it under the pool id and calls `PoolManager.initialize`, so the issuer can't set up a pool the hook would mint into unless it authorised it. Pools use `currency0 = ETH`, `currency1 = token`, LP fee `0` (the spread is the fee).

```solidity
struct PoolConfig {
    uint16 baseAskBps;        // ask spread over fair value
    uint16 baseBidBps;        // bid spread under fair value at or above the reserve target
    uint16 skewBps;           // extra bid spread at a fully drained reserve
    uint16 maxSpreadBps;      // cap on the bid spread
    uint16 targetReserveBps;  // exit reserve target, share of F × supply
    uint32 maxFairValueAge;   // seconds; older fair value halts quotes
    uint128 maxMintPerSwap;   // tokens
}
```

`setPoolConfig` (issuer admin) updates it. In production this sits behind the issuer's timelock.

### 5.3 Settlement (inside `beforeSwap`)

| Leg | Action |
| --- | --- |
| ETH in | `poolManager.take(ETH, hook, amount)`; `ethBalanceOf[pool] += amount` |
| Token out | `poolManager.sync(token)`; `token.mint(poolManager, amount)`; `poolManager.settle()` |
| Token in | `poolManager.take(token, hook, amount)`; `token.burn(hook, amount)` |
| ETH out | `ethBalanceOf[pool] -= amount`; `poolManager.settle{value: amount}()` |

Returned delta: exact input `(+specified, −unspecified)`, exact output `(−specified, +unspecified)`. The hook ends every swap with zero PoolManager delta and its ETH balance equal to the sum of `ethBalanceOf`.

### 5.4 Treasury flush

`flushToTreasury(PoolKey)` is permissionless: it sends `ethBalanceOf − target` to `token.treasury()` when positive. The issuer has the incentive to call it; if nobody does, the ETH stays in the reserve and still counts in fair value, so nothing breaks. ETH never leaves the hook to an external address inside a swap.

## 6. Safety rails

| Rail | Behaviour |
| --- | --- |
| Stale fair value | `block.timestamp − updatedAt > maxFairValueAge` → revert `MintToLiquidityHookStaleFairValue` |
| Zero fair value | revert `MintToLiquidityHookInvalidFairValue` |
| Issuer paused | revert `MintToLiquidityHookIssuerPaused` (both sides) |
| Mint caps | tokens out > `maxMintPerSwap` or > `mintCapRemaining()` → revert |
| Reserve exhausted | ETH out > `ethBalanceOf` → revert `MintToLiquidityHookInsufficientReserve` (a queue is out of prototype scope) |
| Third-party liquidity | `beforeAddLiquidity` reverts |
| Foreign initialisation | `beforeInitialize` reverts unless the hook initialises |
| Config bounds | spreads ≤ 50%, `baseBidBps ≤ maxSpreadBps`, `targetReserveBps ≤ 100%`, `maxFairValueAge > 0` |

## 7. Invariants (Foundry)

1. Fair value per token never decreases as a result of a hook trade.
2. `address(hook).balance == Σ ethBalanceOf[pool]`.
3. A sell never pays out more ETH than the pool's reserve.
4. A buy followed by an equal sell returns at most the ETH paid in (no free round trip).
5. Every swap leaves the hook with no outstanding PoolManager delta (otherwise `unlock` reverts with `CurrencyNotSettled`).

## 8. Prototype scope

**In:** the hook, math library, issuer mock, unit tests for every branch, fuzz tests for the math, invariant tests (§7), exact-input and exact-output in both directions through the v4 test router.

**Out (production work):**

- An ERC-4626 adapter so any vault can plug in without implementing `IMintableToken`
- An exit queue when the reserve is short
- A TWAP or per-block limit on fair-value changes
- Issuer-side timelock on `setPoolConfig`
- Router/quoter integration on a mainnet fork, gas profiling, audit

## 9. Development

```bash
forge build
forge test
forge fmt --check src/ test/
```

## 10. Open questions

- Should the ask also skew (cheaper buys while the reserve is short), or does that invite buying just to drain via sells?
- Should sells beyond the reserve queue, partially fill, or revert (prototype: revert)?
- Is `issuerAdmin()` the right authority for pool registration, or should registration be a one-shot call from the token itself?

## License

MIT
