/**
 * AgentEscrowV4 — Live Demo on Polygon Mainnet
 * Runs a full escrow lifecycle: create → submit work → release → rate
 * Two wallets: buyer (our main wallet) + seller (generated for demo)
 */

import { ethers } from "ethers";

// ── Config ────────────────────────────────────────────────────────────────────
const RPC = "https://polygon-rpc.com";
const BUYER_KEY = "0x1535ac09fc5c3b4ad2bf396ab1f094e1a77c9f682c79ab60bda0722cc28d2f67";
const CONTRACT = "0xf8a7e6b5Decfe1b6F57e3D16d8005BCa5Be88B6A";
const USDCe = "0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174"; // USDC.e on Polygon (6 decimals)
const AMOUNT = 1_000_000n; // 1 USDC.e

// ── ABI (minimal) ─────────────────────────────────────────────────────────────
const ESCROW_ABI = [
  "function createJob(address seller, address token, uint256 amount, uint256 deadline, uint256[] milestoneAmounts, uint256 disputeWindowSeconds) returns (uint256 jobId)",
  "function submitWork(uint256 jobId, bytes32 workHash)",
  "function release(uint256 jobId)",
  "function rateJob(uint256 jobId, uint8 rating)",
  "function getJob(uint256 jobId) view returns (tuple(address buyer, address seller, address token, uint256 amount, uint256 deadline, uint256 disputeWindow, bytes32 workHash, uint64 submittedAt, uint64 disputedAt, uint8 status))",
  "function sellerStats(address seller) view returns (uint256 completedJobs, uint256 disputedJobs, uint256 avgRatingX100, uint256 ratingCount)",
  "function jobCount() view returns (uint256)",
  "event JobCreated(uint256 indexed jobId, address buyer, address seller, address token, uint256 amount, uint256 deadline, uint256 disputeWindow)",
  "event WorkSubmitted(uint256 indexed jobId, bytes32 workHash)",
  "event Released(uint256 indexed jobId, address seller, uint256 sellerAmount, uint256 feeAmount)",
  "event SellerRated(uint256 indexed jobId, address indexed seller, uint8 rating)",
];

const ERC20_ABI = [
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function balanceOf(address account) view returns (uint256)",
  "function transfer(address to, uint256 amount) returns (bool)",
];

// ── Main ──────────────────────────────────────────────────────────────────────
async function main() {
  const provider = new ethers.JsonRpcProvider(RPC);
  const buyer = new ethers.Wallet(BUYER_KEY, provider);
  
  // Generate seller wallet for demo
  const sellerWallet = ethers.Wallet.createRandom().connect(provider);
  
  console.log("═══════════════════════════════════════════════════════════════");
  console.log("  AgentEscrowV4 — Live Demo on Polygon Mainnet");
  console.log("═══════════════════════════════════════════════════════════════");
  console.log(`Buyer:    ${buyer.address}`);
  console.log(`Seller:   ${sellerWallet.address} (generated for demo)`);
  console.log(`Contract: ${CONTRACT}`);
  console.log(`Token:    USDC.e (${USDCe})`);
  console.log(`Amount:   ${Number(AMOUNT) / 1e6} USDC.e`);
  console.log("");

  const escrow = new ethers.Contract(CONTRACT, ESCROW_ABI, buyer);
  const token = new ethers.Contract(USDCe, ERC20_ABI, buyer);

  // Check balances
  const buyerBal = await token.balanceOf(buyer.address);
  const buyerPol = await provider.getBalance(buyer.address);
  console.log(`Buyer USDC.e balance: ${Number(buyerBal) / 1e6}`);
  console.log(`Buyer POL balance:    ${Number(buyerPol) / 1e18}`);
  
  if (buyerBal < AMOUNT) {
    console.error("❌ Not enough USDC.e!");
    return;
  }

  // ── Step 0: Send gas to seller ──────────────────────────────────────────
  console.log("\n── Step 0: Send gas to seller ──");
  const gasTx = await buyer.sendTransaction({
    to: sellerWallet.address,
    value: ethers.parseEther("0.05"), // 0.05 POL for gas
  });
  console.log(`  TX: ${gasTx.hash}`);
  await gasTx.wait();
  console.log("  ✅ Seller funded with 0.05 POL");

  // ── Step 1: Approve token spend ─────────────────────────────────────────
  console.log("\n── Step 1: Approve USDC.e spend ──");
  const allowance = await token.allowance(buyer.address, CONTRACT);
  if (allowance < AMOUNT) {
    const approveTx = await token.approve(CONTRACT, ethers.MaxUint256);
    console.log(`  TX: ${approveTx.hash}`);
    await approveTx.wait();
    console.log("  ✅ Approved");
  } else {
    console.log("  ✅ Already approved");
  }

  // ── Step 2: Create job ──────────────────────────────────────────────────
  console.log("\n── Step 2: Create escrow job ──");
  const deadline = Math.floor(Date.now() / 1000) + 7 * 86400; // 7 days
  const disputeWindow = 6 * 3600; // 6 hours (minimum)
  
  const createTx = await escrow.createJob(
    sellerWallet.address,
    USDCe,
    AMOUNT,
    deadline,
    [], // no milestones
    disputeWindow,
  );
  console.log(`  TX: ${createTx.hash}`);
  const createReceipt = await createTx.wait();
  
  // Parse jobId from event
  let jobId: bigint = 0n;
  for (const log of createReceipt!.logs) {
    try {
      const parsed = escrow.interface.parseLog(log);
      if (parsed?.name === "JobCreated") {
        jobId = parsed.args.jobId;
      }
    } catch {}
  }
  console.log(`  ✅ Job created! ID: ${jobId}`);
  console.log(`  Deadline: ${new Date(deadline * 1000).toISOString()}`);
  console.log(`  Dispute window: ${disputeWindow / 3600}h`);

  // ── Step 3: Submit work (as seller) ─────────────────────────────────────
  console.log("\n── Step 3: Seller submits work ──");
  const deliverable = "Demo deliverable: AgentEscrowV4 live test — job completed successfully";
  const workHash = ethers.keccak256(ethers.toUtf8Bytes(deliverable));
  
  const sellerEscrow = new ethers.Contract(CONTRACT, ESCROW_ABI, sellerWallet);
  const submitTx = await sellerEscrow.submitWork(jobId, workHash);
  console.log(`  TX: ${submitTx.hash}`);
  await submitTx.wait();
  console.log(`  ✅ Work submitted!`);
  console.log(`  Work hash: ${workHash}`);
  console.log(`  Deliverable: "${deliverable}"`);

  // ── Step 4: Release payment (as buyer) ──────────────────────────────────
  console.log("\n── Step 4: Buyer releases payment ──");
  const releaseTx = await escrow.release(jobId);
  console.log(`  TX: ${releaseTx.hash}`);
  const releaseReceipt = await releaseTx.wait();
  
  // Parse amounts from Released event
  for (const log of releaseReceipt!.logs) {
    try {
      const parsed = escrow.interface.parseLog(log);
      if (parsed?.name === "Released") {
        const sellerAmt = parsed.args.sellerAmount;
        const feeAmt = parsed.args.feeAmount;
        console.log(`  ✅ Payment released!`);
        console.log(`  Seller received: ${Number(sellerAmt) / 1e6} USDC.e`);
        console.log(`  Protocol fee:    ${Number(feeAmt) / 1e6} USDC.e (0.5%)`);
      }
    } catch {}
  }

  // ── Step 5: Rate seller (as buyer) ──────────────────────────────────────
  console.log("\n── Step 5: Buyer rates seller ──");
  const rateTx = await escrow.rateJob(jobId, 5);
  console.log(`  TX: ${rateTx.hash}`);
  await rateTx.wait();
  console.log("  ✅ Rated 5 stars! ⭐⭐⭐⭐⭐");

  // ── Summary ─────────────────────────────────────────────────────────────
  console.log("\n═══════════════════════════════════════════════════════════════");
  console.log("  DEMO COMPLETE — Full Escrow Lifecycle on Polygon Mainnet");
  console.log("═══════════════════════════════════════════════════════════════");
  
  const job = await escrow.getJob(jobId);
  const stats = await escrow.sellerStats(sellerWallet.address);
  const totalJobs = await escrow.jobCount();
  
  console.log(`\nJob #${jobId}:`);
  console.log(`  Status:   Released ✅`);
  console.log(`  Buyer:    ${job.buyer}`);
  console.log(`  Seller:   ${job.seller}`);
  console.log(`  Amount:   ${Number(job.amount) / 1e6} USDC.e`);
  console.log(`  WorkHash: ${job.workHash}`);
  
  console.log(`\nSeller Reputation:`);
  console.log(`  Completed: ${stats.completedJobs}`);
  console.log(`  Disputed:  ${stats.disputedJobs}`);
  console.log(`  Avg Rating: ${Number(stats.avgRatingX100) / 100} ⭐ (${stats.ratingCount} reviews)`);
  
  console.log(`\nProtocol Stats:`);
  console.log(`  Total jobs on contract: ${totalJobs}`);
  
  console.log(`\n── Transaction Hashes (verify on Polygonscan) ──`);
  console.log(`  Gas funding:  https://polygonscan.com/tx/${gasTx.hash}`);
  console.log(`  Create job:   https://polygonscan.com/tx/${createTx.hash}`);
  console.log(`  Submit work:  https://polygonscan.com/tx/${submitTx.hash}`);
  console.log(`  Release:      https://polygonscan.com/tx/${releaseTx.hash}`);
  console.log(`  Rate:         https://polygonscan.com/tx/${rateTx.hash}`);
}

main().catch(console.error);
