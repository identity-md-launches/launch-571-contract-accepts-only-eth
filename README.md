# OneEthCap

A contract that accepts only ETH and never accepts more than 1 ETH in total, plus the
fixed-supply `LaunchToken` the IdentityMD project launch requires.

## Contracts

| Contract      | File                   | Constructor arguments                   |
|---------------|------------------------|-----------------------------------------|
| `LaunchToken` | `src/LaunchToken.sol`  | none                                    |
| `OneEthCap`   | `src/OneEthCap.sol`    | `address beneficiary` (use `$owner`)    |

### OneEthCap

**Accepting ETH**

- ETH arrives through `receive()` (plain transfer, empty calldata) or `deposit()`.
- Every accepted deposit is added to `totalAccepted`. A deposit that would push the total above
  `CAP` (exactly 1 ether) reverts with `CapExceeded(remaining, requested)`. The whole deposit is
  refused; there are no partial fills.
- Zero-value deposits revert with `ZeroValue`.
- The cap is **lifetime**, not a balance cap. Once 1 ETH has been accepted the contract never
  accepts another wei, even after its balance has been swept out. `remaining()` reports the room
  left.

**Only ETH**

- Any call with calldata that is not a declared function reverts in `fallback()` with `OnlyEth`,
  whether or not it carries value.
- No ERC-721, ERC-1155 or ERC-777 receiver hooks are implemented, so `safeTransferFrom` of an NFT
  and ERC-777 `send` to this address revert at the token.
- A plain ERC-20 `transfer` writes only to the token's own storage and no recipient can refuse it.
  Such tokens are stuck in this contract permanently; there is no rescue function by design.

**Getting ETH out**

- `sweep()` pushes the entire balance to the immutable `beneficiary` and is callable by anyone.
  Only the beneficiary ever receives funds, so open access is safe; it also means no key is needed
  to move the money.
- `sweep()` reverts with `NothingToSweep` on an empty balance and with `SweepFailed` if the
  beneficiary rejects ETH. A revert rolls back `totalSwept`, so accounting stays exact.
- State is settled before the external call. A beneficiary that re-enters `sweep()` finds an empty
  balance and gets `NothingToSweep`.

**Forced ETH**

ETH forced in by `SELFDESTRUCT` or by naming the contract as a block-reward recipient bypasses
`receive()` and cannot be refused by any contract. It does not count toward `totalAccepted`, so the
1 ETH limit still governs every real deposit. `sweep()` forwards it to the beneficiary with the
rest.

### LaunchToken

Standard fixed-supply ERC-20: name `OneEthCap`, symbol `ONECAP`, 18 decimals, exactly
1,000,000,000 tokens (10^27 minor units) minted to `msg.sender` in the constructor. No mint, burn,
owner, pause, blocklist, fee or upgrade functions. The brief did not ask for any token behaviour
beyond this, and nothing beyond this is provided.

## Deployment parameters

| Parameter     | Value                                                      |
|---------------|------------------------------------------------------------|
| `beneficiary` | The project owner's wallet. In `launch.json` use `$owner`. |

Do not pass the factory or `msg.sender` as the beneficiary: constructors run with the immutable
factory as `msg.sender`, and ETH swept to it would be unrecoverable. The constructor rejects the
zero address.

`script/Deploy.s.sol` is a reviewable helper only. Its `deploy(address)` function is what the
tests call; `run()` reads `BENEFICIARY` from the environment for manual use. The IdentityMD launch
deploys through `ProjectFactory` from the manifest and does not use this script. This assignment
authorises no transactions and holds no keys.

## Operational responsibilities

- **Beneficiary**: must be an address that can receive ETH. If it is a contract whose `receive`
  reverts, every `sweep()` fails and the ETH is locked until that changes (it cannot change for
  this contract, since the beneficiary is immutable). Verify it before launch.
- **Sweeping**: permissionless. The beneficiary or anyone else calls `sweep()` when they want the
  balance delivered. No schedule or keeper is required.
- **Monitoring**: `Deposited(from, amount, totalAccepted)` and `Swept(to, amount)` events cover
  every state change.
- **No admin**: there is no owner, pause, upgrade or rescue path. Nothing can raise the cap or
  change the beneficiary after deployment.

## Assumptions

- "1 ETH in total" means a cumulative lifetime limit of exactly `1 ether` across all senders, not
  a per-sender limit and not a current-balance limit.
- "Accepts only ETH" is enforced as far as the EVM allows: value with unknown calldata, NFT safe
  transfers and ERC-777 sends are refused. Plain ERC-20 transfers and forced ETH cannot be refused
  by any contract.
- Accepted ETH belongs to the beneficiary. The brief did not say who should receive it, so the
  deployment names one explicitly rather than locking funds forever.
- No fee logic lives in either contract. Pool fees are handled by the launch factory.

## Testing

```bash
forge build
forge test
forge fmt --check
```

The suite has unit tests for every success and failure path (exact cap, cumulative cap, crossing
the cap, one wei past full, zero value, lifetime after sweep, unknown calldata, NFT and ERC-777
hooks, sweep to a rejecting beneficiary, reentrancy during sweep, forced ETH), two fuzz tests that
check acceptance matches the cap rule exactly, and an invariant suite that checks
`totalAccepted <= CAP` and conservation of funds (`balance + totalSwept == totalAccepted`) under
random deposit and sweep sequences. Tests read no environment variables and are order-independent.

## Dependencies

`lib/forge-std` is vendored as ordinary files; there are no submodules. The compiler is pinned to
`solc 0.8.26` in `foundry.toml`, with `bytecode_hash = "none"`, `ffi` off and no filesystem
permissions.

## Security review status

Tests passing are not an audit. The contract holds other people's ETH (at most 1 ETH) and should
get the independent adversarial review before release. Tools run here: `forge build`,
`forge test` (256 fuzz runs, 64 invariant runs at depth 32) and `forge fmt --check`. Slither and
Mythril were not run. Explorer verification after deployment is the network deployer's open item.
