/**
 * AgentEscrowV4 — Live Demo on Polygon Mainnet
 * Full lifecycle: create → submit work → release → rate
 */

import { ethers } from "../frontend/node_modules/ethers/dist/ethers.min.js";

const RPC = "https://polygon.drpc.org";
const BUYER_KEY = "0x1535ac09fc5c3b4ad2bf396ab1f094e1a77c9f682c79ab60bda0722cc28d2f67";
const CONTRACT = "0xf8a7e6b5Decfe1b6F57e3D16d8005BCa5Be88B6A";
const USDCe = "0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174";
const AMOUNT = 1000000n; // 1 USDC.e

const ESCROW_ABI = [
  "function createJob(address seller, address token, uint256 amount, uint256 deadline, uint256[] milestoneAmounts, uint256 disputeWindowSeconds) returns (uint256 jobId)",
  "function submitWork(uint256 jobId, bytes32 workHash)",
  "function release(uint256 jobId)",
  "function rateJob(uint256 jobId, uint8 rating)",
  "function getJob(uint256 jobId) view returns (tuple(address buyer, address seller, address token, uint256 amount, uint256 deadline, uint256 disputeWindow, bytes32 workHash, uint64 submittedAt, uint64 disputedAt, uint8 status))",
  "function sellerStats(address seller) view returns (uint256 completedJobs, uint256 disputedJobs, uint256 avgRatingX100, uint256 ratingCount)",
  "function jobCount() view returns (uint256)",
  "event JobCreated(uint256 indexed jobId, address buyer, address seller, address token, uint256 amount, uint256 deadline, uint256 disputeWindow)",
  "event Released(uint256 indexed jobId, address seller, uint256 sellerAmount, uint256 feeAmount)",
  "event SellerRated(uint256 indexed jobId, address indexed seller, uint8 rating)",
];

const ERC20_ABI = [
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function balanceOf(address account) view returns (uint256)",
];

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC);
  const buyer = new ethers.Wallet(BUYER_KEY, provider);
  const sellerWallet = ethers.Wallet.createRandom().connect(provider);

  console.log("═══════════════════════════════════════════════════════════");
  console.log("  AgentEscrowV4 — Live Demo on Polygon Mainnet");
  console.log("═══════════════════════════════════════════════════════════");
  console.log(`Buyer:    ${buyer.address}`);
  console.log(`Seller:   ${sellerWallet.address} (generated)`);
  console.log(`Contract: ${CONTRACT}`);
  console.log(`Amount:   1 USDC.e\n`);

  const escrow = new ethers.Contract(CONTRACT, ESCROW_ABI, buyer);
  const token = new ethers.Contract(USDCe, ERC20_ABI, buyer);

  const buyerBal = await token.balanceOf(buyer.address);
  console.log(`Buyer USDC.e: ${Number(buyerBal) / 1e6}`);
  if (buyerBal < AMOUNT) { console.error("❌ Not enough USDC.e!"); return; }

  // Step 0: Fund seller with gas
  console.log("\n── Step 0: Fund seller with gas ──");
  const gasTx = await buyer.sendTransaction({
    to: sellerWallet.address,
    value: ethers.parseEther("0.03"),
  });
  await gasTx.wait();
  console.log(`  ✅ 0.03 POL sent | TX: ${gasTx.hash}`);

  // Step 1: Approve
  console.log("\n── Step 1: Approve USDC.e ──");
  const allowance = await token.allowance(buyer.address, CONTRACT);
  if (allowance < AMOUNT) {
    const appTx = await token.approve(CONTRACT, ethers.MaxUint256);
    await appTx.wait();
    console.log(`  ✅ Approved | TX: ${appTx.hash}`);
  } else {
    console.log("  ✅ Already approved");
  }

  // Step 2: Create job
  console.log("\n── Step 2: Create escrow job ──");
  const deadline = Math.floor(Date.now() / 1000) + 7 * 86400;
  const createTx = await escrow.createJob(
    sellerWallet.address, USDCe, AMOUNT, deadline, [], 6 * 3600
  );
  const createRx = await createTx.wait();
  let jobId = 0n;
  for (const log of createRx.logs) {
    try {
      const p = escrow.interface.parseLog(log);
      if (p?.name === "JobCreated") jobId = p.args.jobId;
    } catch {}
  }
  console.log(`  ✅ Job #${jobId} created | TX: ${createTx.hash}`);

  // Step 3: Submit work (seller)
  console.log("\n── Step 3: Seller submits work ──");
  const deliverable = "AgentEscrowV4 live demo — job completed successfully";
  const workHash = ethers.keccak256(ethers.toUtf8Bytes(deliverable));
  const sellerEscrow = new ethers.Contract(CONTRACT, ESCROW_ABI, sellerWallet);
  const submitTx = await sellerEscrow.submitWork(jobId, workHash);
  await submitTx.wait();
  console.log(`  ✅ Work submitted | TX: ${submitTx.hash}`);
  console.log(`  Hash: ${workHash}`);

  // Step 4: Release (buyer)
  console.log("\n── Step 4: Buyer releases payment ──");
  const releaseTx = await escrow.release(jobId);
  const releaseRx = await releaseTx.wait();
  for (const log of releaseRx.logs) {
    try {
      const p = escrow.interface.parseLog(log);
      if (p?.name === "Released") {
        console.log(`  ✅ Released!`);
        console.log(`  Seller: ${Number(p.args.sellerAmount) / 1e6} USDC.e`);
        console.log(`  Fee:    ${Number(p.args.feeAmount) / 1e6} USDC.e`);
      }
    } catch {}
  }

  // Step 5: Rate (buyer)
  console.log("\n── Step 5: Buyer rates seller ──");
  const rateTx = await escrow.rateJob(jobId, 5);
  await rateTx.wait();
  console.log("  ✅ Rated 5 stars ⭐⭐⭐⭐⭐");

  // Summary
  const stats = await escrow.sellerStats(sellerWallet.address);
  const totalJobs = await escrow.jobCount();

  console.log("\n═══════════════════════════════════════════════════════════");
  console.log("  DEMO COMPLETE");
  console.log("═══════════════════════════════════════════════════════════");
  console.log(`Job #${jobId} — Status: Released ✅`);
  console.log(`Seller reputation: ${Number(stats.avgRatingX100)/100}⭐ (${stats.ratingCount} reviews)`);
  console.log(`Total jobs on contract: ${totalJobs}`);
  console.log(`\nPolygonscan links:`);
  console.log(`  Create:  https://polygonscan.com/tx/${createTx.hash}`);
  console.log(`  Submit:  https://polygonscan.com/tx/${submitTx.hash}`);
  console.log(`  Release: https://polygonscan.com/tx/${releaseTx.hash}`);
  console.log(`  Rate:    https://polygonscan.com/tx/${rateTx.hash}`);
}

main().catch(console.error);
