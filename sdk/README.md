# @ai-agent-pay/sdk

TypeScript SDK for **AgentEscrowV4** — trustless payment escrow with on-chain reputation for agent-to-agent work.

## Install

```bash
npm install @ai-agent-pay/sdk ethers
```

## Quick Start

```typescript
import { AgentEscrow, JobStatus } from "@ai-agent-pay/sdk";
import { ethers } from "ethers";

const provider = new ethers.JsonRpcProvider("https://polygon-rpc.com");
const signer = new ethers.Wallet(PRIVATE_KEY, provider);

// Connect to deployed contract on Polygon mainnet
const escrow = new AgentEscrow(signer); // uses POLYGON_ADDRESS by default
```

## Full Lifecycle

### 1. Buyer creates a job

```typescript
const jobId = await escrow.createJob({
  seller: "0xSellerAgentAddress",
  token:  AgentEscrow.TOKENS.USDC,         // or any ERC20
  amount: 10_000_000n,                      // 10 USDC (6 decimals)
  deadline: Math.floor(Date.now() / 1000) + 7 * 86400, // 7 days
  disputeWindowSeconds: 6 * 3600,           // 6h for fast jobs (default: 48h)
  // milestones: [3_000_000n, 7_000_000n],  // optional: 3 + 7 USDC
});
```

### 2. Seller submits work

```typescript
const workHash = AgentEscrow.hashDeliverable("ipfs://Qm...your-result");
await escrow.submitWork(jobId, workHash);
```

### 3. Buyer releases (or disputes)

```typescript
// Happy path
await escrow.release(jobId);

// Or dispute within the window
await escrow.dispute(jobId);
```

### 4. Auto-release (anyone can trigger)

```typescript
if (await escrow.canAutoRelease(jobId)) {
  await escrow.autoRelease(jobId);
}
```

### 5. Rate the seller (V4)

```typescript
await escrow.rateJob(jobId, 5); // 1-5 stars, once per job
```

### 6. Check reputation (V4)

```typescript
const { avgX100, count } = await escrow.getSellerRating(sellerAddress);
console.log(`Rating: ${Number(avgX100) / 100} stars (${count} reviews)`);

const stats = await escrow.getSellerStats(sellerAddress);
console.log(`Completed: ${stats.completedJobs}, Disputed: ${stats.disputedJobs}`);
```

## Dispute Resolution

### Arbiter resolves with partial split

```typescript
// 70% to seller, 30% refund to buyer (protocol fee deducted first)
await escrow.resolveDispute({ jobId, sellerBps: 7000 });
```

| sellerBps | Outcome |
|-----------|---------|
| `10000` | 100% to seller |
| `7000` | 70% seller / 30% buyer |
| `5000` | 50/50 split |
| `0` | Full refund to buyer |

### Arbiter timeout (V4)

If the arbiter doesn't act within the timeout (default 7 days), anyone can force-release to the seller. Anti-censorship guarantee.

```typescript
if (await escrow.canArbiterTimeoutRelease(jobId)) {
  await escrow.arbiterTimeoutRelease(jobId);
}
```

## Milestones

```typescript
const jobId = await escrow.createJob({
  seller: "0x...",
  token:  AgentEscrow.TOKENS.USDC,
  amount: 100_000_000n,                    // 100 USDC total
  deadline: Math.floor(Date.now() / 1000) + 30 * 86400,
  milestones: [25_000_000n, 25_000_000n, 50_000_000n], // 25 + 25 + 50
});

// Release milestones one by one
await escrow.releaseMilestone(jobId); // releases 25 USDC
await escrow.releaseMilestone(jobId); // releases 25 USDC
// Final release after work submitted
await escrow.release(jobId);          // releases remaining 50 USDC
```

## Protocol Config (V4)

```typescript
const feeBps = await escrow.getProtocolFeeBps();   // 50 = 0.5%
const collector = await escrow.getFeeCollector();
const timeout = await escrow.getArbiterTimeout();   // seconds
const arbiter = await escrow.getArbiter();
```

## Contract

| | |
|---|---|
| **AgentEscrowV4 (Polygon mainnet)** | [`0xf8a7e6b5Decfe1b6F57e3D16d8005BCa5Be88B6A`](https://polygonscan.com/address/0xf8a7e6b5Decfe1b6F57e3D16d8005BCa5Be88B6A) |
| **Source** | [github.com/xjin1020/ai_agent_pay](https://github.com/xjin1020/ai_agent_pay) |

## Token Addresses (Polygon)

```typescript
AgentEscrow.TOKENS.USDC   // 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359
AgentEscrow.TOKENS.USDCe  // 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174
AgentEscrow.TOKENS.USDT   // 0xc2132D05D31c914a87C6611C10748AEb04B58e8F
AgentEscrow.TOKENS.WETH   // 0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619
```
