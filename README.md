# AgentEscrowV2

Trustless payment escrow for agent-to-agent work. Built for the SYNTHESIS hackathon.

## What it does

- Buyer locks funds in escrow when creating a job
- Seller submits a `workHash` (SHA256 of deliverable) to prove delivery
- 48h dispute window: buyer can dispute or release; auto-release if silent
- Buyer gets refund if seller never shows up before deadline
- Optional milestone payments (25/50/100% partial release)
- Works with any ERC20 on any EVM chain

## Deployed Contracts (Polygon Mainnet)

| Contract | Address | TX |
|---|---|---|
| **AgentEscrowV3** ✨ | [`0xf8a7e6b5Decfe1b6F57e3D16d8005BCa5Be88B6A`](https://polygonscan.com/address/0xf8a7e6b5Decfe1b6F57e3D16d8005BCa5Be88B6A) | [`0xc5cd28...`](https://polygonscan.com/tx/0xc5cd2816b6260732d25748446a6c97497a102202f0bc05f50b12fff3fcfe8ec9) |
| **AgentEscrowV2Fixed** | [`0x9C8eefb386C395089D7906C67b48A3fd5ca14B9c`](https://polygonscan.com/address/0x9C8eefb386C395089D7906C67b48A3fd5ca14B9c) | [`0x700033...`](https://polygonscan.com/tx/0x7000334d05fe02ad378453724210bc33a9b2035f33aa012a4dde483b28d16b76) |
| **Network** | Polygon (chain 137) | |
| **Arbiter** | `0xe75895c6B674bcdBe910ed4d33fabCd6689290Fb` | |

## Security Audit

Full audit in [`SECURITY_AUDIT.md`](./SECURITY_AUDIT.md).

**Findings:**

| Severity | Issue | Status |
|----------|-------|--------|
| 🔴 Critical | Milestone double-payment drains victim jobs | Fixed in V2Fixed |
| 🟡 Medium | Disputed funds locked forever (no resolver) | Fixed — arbiter added |
| 🟡 Medium | buyer == seller not rejected | Fixed |
| 🔵 Info | Raw IERC20 breaks USDT-style tokens | Fixed — SafeTransfer lib |

## Contracts

- `src/AgentEscrowV2.sol` — original (has critical bug, kept for reference)
- `src/AgentEscrowV2Fixed.sol` — patched version, all bugs resolved

## Tests

```bash
# Install Foundry: https://book.getfoundry.sh/getting-started/installation
forge test -v
```

**Results:** 47 tests pass, original critical bug confirmed by 1 intentional failing test.

- `test/AgentEscrowV2.t.sol` — 32 tests proving original bugs exist
- `test/AgentEscrowV2Fixed.t.sol` — 15 tests verifying all fixes

## Key Fix: Milestone Accounting

Original bug — seller gets paid twice:
```solidity
// BUGGY: always sends full job.amount ignoring milestone payouts
function _release(Job storage job, uint256 jobId) internal {
    job.status = Status.Released;
    IERC20(job.token).transfer(job.seller, job.amount); // ← drains other jobs
}
```

Fix — track what's already been paid:
```solidity
// FIXED: only send remainder after milestone payouts
mapping(uint256 => uint256) public releasedAmount;

function _release(Job storage job, uint256 jobId) internal {
    job.status = Status.Released;
    uint256 remaining = job.amount - releasedAmount[jobId];
    if (remaining > 0) job.token.safeTransfer(job.seller, remaining);
}
```
