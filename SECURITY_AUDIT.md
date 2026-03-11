# AgentEscrowV2 — Security Audit Report

**Auditor:** Bob (AI security agent)  
**Date:** 2026-03-10  
**Scope:** `AgentEscrowV2.sol`  
**Test results:** 33 total — 31 PASS, 1 FAIL (critical bug confirmed)

---

## Summary

| Severity | Count | Status |
|----------|-------|--------|
| 🔴 Critical | 1 | Confirmed by test |
| 🟡 Medium | 2 | Confirmed by test |
| 🔵 Info | 3 | Noted |

---

## 🔴 CRITICAL — Milestone Double Payment (Fund Drain)

**Function:** `releaseMilestone()` + `release()` / `autoRelease()`  
**Test:** `test_CRITICAL_MilestoneDoubleSpend` — **FAILS**

### What happens

1. Buyer creates job with milestones `[50, 50]`, total = 100 USDC
2. Buyer calls `releaseMilestone()` → seller gets 50 USDC
3. Seller submits work; auto-release fires after 48h
4. `_release()` transfers `job.amount` = **100 USDC** to seller
5. Escrow only holds 50 USDC for this job — **steals 50 from another job**

### Root cause

`_release()` always uses `job.amount` without subtracting already-released milestone amounts:

```solidity
function _release(Job storage job, uint256 jobId) internal {
    job.status = Status.Released;
    require(IERC20(job.token).transfer(job.seller, job.amount), "Transfer failed"); // ← always full amount
}
```

### Impact

- Seller double-paid
- Contract drains funds from other users' jobs
- Can be triggered accidentally (not just maliciously)

### Fix

Track released amounts and only send the remainder:

```solidity
mapping(uint256 => uint256) public releasedAmount; // add this

function releaseMilestone(uint256 jobId) external {
    // ... existing checks ...
    uint256 slice = ms[idx];
    releasedAmount[jobId] += slice;  // ← track what's been paid
    require(IERC20(job.token).transfer(job.seller, slice), "Transfer failed");
    emit MilestoneReleased(jobId, idx, slice);
}

function _release(Job storage job, uint256 jobId) internal {
    job.status = Status.Released;
    uint256 remaining = job.amount - releasedAmount[jobId];  // ← only send remainder
    if (remaining > 0) {
        require(IERC20(job.token).transfer(job.seller, remaining), "Transfer failed");
    }
    emit Released(jobId, job.seller, remaining);
}
```

---

## 🟡 MEDIUM — Disputed Funds Locked Forever

**Function:** `dispute()`  
**Test:** `test_INFO_DisputedFundsLockedForever` — PASS (confirms behavior)

### What happens

Once a job enters `Status.Disputed`, there is no code path to recover funds. No arbiter, no resolver, no timeout. Funds are permanently locked.

### Impact

- Any buyer can accidentally (or maliciously) lock funds by calling `dispute()`
- No recovery mechanism even if both parties agree to settle

### Fix Options

1. **Arbiter address** set at job creation — arbiter can call `resolveDispute(jobId, winner)`
2. **Mutual release** — if both buyer and seller call `resolve()`, release funds to seller
3. **Timeout refund** — if dispute unresolved after N days, auto-refund buyer

Recommended minimal fix:
```solidity
address public arbiter; // set in constructor

function resolveDispute(uint256 jobId, bool payoutSeller) external {
    require(msg.sender == arbiter, "Not arbiter");
    Job storage job = jobs[jobId];
    require(job.status == Status.Disputed, "Not disputed");
    if (payoutSeller) {
        job.status = Status.Released;
        IERC20(job.token).transfer(job.seller, job.amount);
    } else {
        job.status = Status.Refunded;
        IERC20(job.token).transfer(job.buyer, job.amount);
    }
}
```

---

## 🟡 MEDIUM — buyer == seller Allowed

**Test:** `test_SECURITY_BuyerEqualsSeller` — PASS (confirms vulnerability)

### What happens

A user can create a job where `seller = msg.sender`. They:
1. Submit work as themselves
2. Wait 48h → auto-release
3. Get funds back (plus any yield if integrated with DeFi)

In isolation this isn't a theft — it's their own money. But combined with referral/incentive systems or protocol fee structures, it could be abused.

### Fix

```solidity
require(seller != msg.sender, "Buyer cannot be seller");
require(seller != address(0), "Invalid seller");
```

---

## 🔵 INFO — SafeERC20 Not Used (Despite Comment)

**Comment says:** "Uses SafeERC20, works with any ERC20"  
**Reality:** Uses raw `IERC20` interface with `require(transfer(...))` pattern

### Impact

- USDT and some older tokens return `void` instead of `bool` from `transfer()`
- These calls would revert even on success
- The contract does NOT work with USDT on mainnet

### Fix

Use OpenZeppelin's `SafeERC20` with `safeTransfer()` / `safeTransferFrom()`.

---

## 🔵 INFO — Zero-Address Seller Accepted

**Test:** `test_SECURITY_SellerZeroAddress` — PASS (confirms vulnerability)

If `seller = address(0)`:
- Nobody can call `submitWork()` (require fails)
- Buyer's funds are locked until deadline, then refundable
- Mostly harmless but should be validated

**Fix:** `require(seller != address(0), "Invalid seller");`

---

## 🔵 INFO — Empty Work Hash Guard Works

`require(workHash != bytes32(0), "Empty hash")` correctly prevents empty submissions.  
**Test:** `test_SECURITY_EmptyWorkHash_Rejected` — PASS ✅

---

## What's Done Well ✅

- CEI (Checks-Effects-Interactions) pattern followed in all state transitions — **no reentrancy risk**
- Status machine correctly blocks double-release, double-refund
- 48h dispute window is well-designed for the use case  
- `autoRelease` is callable by anyone (good — prevents buyer censorship)
- Milestone sum validation prevents misconfigured jobs
- `workHash` requirement prevents ghost deliveries

---

## Recommended Priority Order

1. **Fix Critical:** Milestone double-payment accounting (ship blocker)
2. **Fix Medium:** Add dispute resolver (arbiter or mutual agreement)
3. **Fix Medium:** Add `require(seller != msg.sender && seller != address(0))`
4. **Info:** Replace raw `IERC20` with `SafeERC20` for token compatibility
