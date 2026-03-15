import { useState } from "react";
import { Contract, keccak256, toUtf8Bytes, formatUnits, type BrowserProvider } from "ethers";
import { CONTRACT_ADDRESS, ESCROW_ABI, TOKENS, STATUS_LABELS, STATUS_COLORS } from "../contract";
import Spinner from "./Spinner";
import type { Toast } from "../hooks";

interface JobData {
  buyer: string;
  seller: string;
  token: string;
  amount: bigint;
  deadline: bigint;
  disputeWindow: bigint;
  workHash: string;
  submittedAt: bigint;
  disputedAt: bigint;
  status: number;
}

interface Props {
  provider: BrowserProvider | null;
  account: string | null;
  addToast: (msg: string, type: Toast["type"]) => void;
}

function getTokenInfo(addr: string) {
  for (const t of Object.values(TOKENS)) {
    if (t.address.toLowerCase() === addr.toLowerCase()) return t;
  }
  return { symbol: "???", decimals: 18, address: addr };
}

export default function JobViewer({ provider, account, addToast }: Props) {
  const [jobIdInput, setJobIdInput] = useState("");
  const [job, setJob] = useState<JobData | null>(null);
  const [milestones, setMilestones] = useState<bigint[]>([]);
  const [remaining, setRemaining] = useState<bigint>(0n);
  const [rated, setRated] = useState(false);
  const [loading, setLoading] = useState(false);
  const [actionLoading, setActionLoading] = useState<string | null>(null);
  const [rating, setRating] = useState(5);
  const [workHashInput, setWorkHashInput] = useState("");

  const fetchJob = async () => {
    if (!provider) {
      addToast("Connect wallet first", "error");
      return;
    }
    try {
      setLoading(true);
      setJob(null);
      const contract = new Contract(CONTRACT_ADDRESS, ESCROW_ABI, provider);
      const j = await contract.getJob(BigInt(jobIdInput));
      const ms = await contract.getMilestones(BigInt(jobIdInput));
      const rem = await contract.remainingAmount(BigInt(jobIdInput));
      const isRated = await contract.jobRated(BigInt(jobIdInput));
      setJob({
        buyer: j[0],
        seller: j[1],
        token: j[2],
        amount: j[3],
        deadline: j[4],
        disputeWindow: j[5],
        workHash: j[6],
        submittedAt: j[7],
        disputedAt: j[8],
        status: Number(j[9]),
      });
      setMilestones([...ms]);
      setRemaining(rem);
      setRated(isRated);
    } catch (err: any) {
      addToast(err.reason || err.message || "Failed to fetch job", "error");
    } finally {
      setLoading(false);
    }
  };

  const execAction = async (action: string) => {
    if (!provider || !account) {
      addToast("Connect wallet first", "error");
      return;
    }
    try {
      setActionLoading(action);
      const signer = await provider.getSigner();
      const contract = new Contract(CONTRACT_ADDRESS, ESCROW_ABI, signer);
      let tx;

      switch (action) {
        case "submitWork": {
          const hash = workHashInput.startsWith("0x")
            ? workHashInput
            : keccak256(toUtf8Bytes(workHashInput));
          tx = await contract.submitWork(BigInt(jobIdInput), hash);
          break;
        }
        case "release":
          tx = await contract.release(BigInt(jobIdInput));
          break;
        case "dispute":
          tx = await contract.dispute(BigInt(jobIdInput));
          break;
        case "refund":
          tx = await contract.refund(BigInt(jobIdInput));
          break;
        case "autoRelease":
          tx = await contract.autoRelease(BigInt(jobIdInput));
          break;
        case "arbiterTimeout":
          tx = await contract.arbiterTimeoutRelease(BigInt(jobIdInput));
          break;
        case "releaseMilestone":
          tx = await contract.releaseMilestone(BigInt(jobIdInput));
          break;
        case "rate":
          tx = await contract.rateJob(BigInt(jobIdInput), rating);
          break;
        default:
          return;
      }

      addToast("Transaction submitted...", "info");
      await tx.wait();
      addToast(`${action} successful!`, "success");
      await fetchJob();
    } catch (err: any) {
      addToast(err.reason || err.message || `${action} failed`, "error");
    } finally {
      setActionLoading(null);
    }
  };

  const tokenInfo = job ? getTokenInfo(job.token) : null;

  return (
    <div className="space-y-4">
      {/* Search */}
      <div className="bg-[#111118] border border-[#1e1e2e] rounded-xl p-5">
        <div className="flex gap-2">
          <input
            type="number"
            value={jobIdInput}
            onChange={(e) => setJobIdInput(e.target.value)}
            placeholder="Enter Job ID"
            className="flex-1 px-3 py-2.5 bg-[#0a0a0f] border border-[#1e1e2e] rounded-lg text-white text-sm focus:border-blue-500 focus:outline-none"
          />
          <button
            onClick={fetchJob}
            disabled={loading || !jobIdInput}
            className="px-5 py-2.5 bg-blue-600 hover:bg-blue-700 disabled:bg-gray-700 text-white rounded-lg text-sm font-medium transition-colors flex items-center gap-2"
          >
            {loading ? <Spinner className="w-4 h-4" /> : "Lookup"}
          </button>
        </div>
      </div>

      {/* Job Details */}
      {job && tokenInfo && (
        <div className="bg-[#111118] border border-[#1e1e2e] rounded-xl p-5 space-y-4">
          <div className="flex items-center justify-between">
            <h3 className="text-lg font-semibold text-white">Job #{jobIdInput}</h3>
            <span className={`px-3 py-1 rounded-full text-xs font-medium ${STATUS_COLORS[job.status]} bg-white/5`}>
              {STATUS_LABELS[job.status]}
            </span>
          </div>

          <div className="grid grid-cols-1 sm:grid-cols-2 gap-3 text-sm">
            <div>
              <span className="text-gray-500">Buyer:</span>
              <p className="font-mono text-gray-300 break-all">{job.buyer}</p>
            </div>
            <div>
              <span className="text-gray-500">Seller:</span>
              <p className="font-mono text-gray-300 break-all">{job.seller}</p>
            </div>
            <div>
              <span className="text-gray-500">Amount:</span>
              <p className="text-white font-semibold">
                {formatUnits(job.amount, tokenInfo.decimals)} {tokenInfo.symbol}
              </p>
            </div>
            <div>
              <span className="text-gray-500">Remaining:</span>
              <p className="text-white font-semibold">
                {formatUnits(remaining, tokenInfo.decimals)} {tokenInfo.symbol}
              </p>
            </div>
            <div>
              <span className="text-gray-500">Deadline:</span>
              <p className="text-gray-300">{new Date(Number(job.deadline) * 1000).toLocaleString()}</p>
            </div>
            <div>
              <span className="text-gray-500">Dispute Window:</span>
              <p className="text-gray-300">{Number(job.disputeWindow) / 3600}h</p>
            </div>
            <div>
              <span className="text-gray-500">Work Hash:</span>
              <p className="font-mono text-gray-300 break-all text-xs">
                {job.workHash === "0x0000000000000000000000000000000000000000000000000000000000000000"
                  ? "Not submitted"
                  : job.workHash}
              </p>
            </div>
            <div>
              <span className="text-gray-500">Token:</span>
              <a
                href={`https://polygonscan.com/token/${job.token}`}
                target="_blank"
                rel="noopener noreferrer"
                className="text-blue-400 hover:text-blue-300 font-mono text-xs block break-all"
              >
                {job.token}
              </a>
            </div>
          </div>

          {milestones.length > 0 && (
            <div>
              <span className="text-gray-500 text-sm">Milestones:</span>
              <div className="flex flex-wrap gap-2 mt-1">
                {milestones.map((m, i) => (
                  <span key={i} className="px-2 py-1 bg-[#0a0a0f] rounded text-xs text-gray-300 font-mono">
                    #{i + 1}: {formatUnits(m, tokenInfo.decimals)} {tokenInfo.symbol}
                  </span>
                ))}
              </div>
            </div>
          )}

          {/* Actions */}
          <div className="border-t border-[#1e1e2e] pt-4 space-y-3">
            <h4 className="text-sm font-medium text-gray-400 uppercase tracking-wider">Actions</h4>

            {/* Submit Work (seller, status=Created) */}
            {job.status === 0 && (
              <div className="flex gap-2">
                <input
                  type="text"
                  value={workHashInput}
                  onChange={(e) => setWorkHashInput(e.target.value)}
                  placeholder="Work hash or content to hash"
                  className="flex-1 px-3 py-2 bg-[#0a0a0f] border border-[#1e1e2e] rounded-lg text-white text-sm focus:border-blue-500 focus:outline-none"
                />
                <ActionButton
                  label="Submit Work"
                  action="submitWork"
                  loading={actionLoading}
                  onClick={() => execAction("submitWork")}
                  color="blue"
                />
              </div>
            )}

            {/* Release / Dispute (buyer, status=WorkSubmitted) */}
            {job.status === 1 && (
              <div className="flex gap-2 flex-wrap">
                <ActionButton label="Release Payment" action="release" loading={actionLoading} onClick={() => execAction("release")} color="green" />
                <ActionButton label="Dispute" action="dispute" loading={actionLoading} onClick={() => execAction("dispute")} color="orange" />
                <ActionButton label="Auto Release" action="autoRelease" loading={actionLoading} onClick={() => execAction("autoRelease")} color="purple" />
              </div>
            )}

            {/* Refund (buyer, status=Created, past deadline) */}
            {job.status === 0 && (
              <ActionButton label="Refund (past deadline)" action="refund" loading={actionLoading} onClick={() => execAction("refund")} color="red" />
            )}

            {/* Arbiter Timeout (status=Disputed) */}
            {job.status === 4 && (
              <ActionButton label="Arbiter Timeout Release" action="arbiterTimeout" loading={actionLoading} onClick={() => execAction("arbiterTimeout")} color="purple" />
            )}

            {/* Milestone Release */}
            {milestones.length > 0 && (job.status === 0 || job.status === 1) && (
              <ActionButton label="Release Milestone" action="releaseMilestone" loading={actionLoading} onClick={() => execAction("releaseMilestone")} color="blue" />
            )}

            {/* Rate (buyer, status=Released or PartiallyResolved, not rated) */}
            {(job.status === 2 || job.status === 5) && !rated && (
              <div className="flex items-center gap-3">
                <div className="flex gap-1">
                  {[1, 2, 3, 4, 5].map((star) => (
                    <button
                      key={star}
                      type="button"
                      onClick={() => setRating(star)}
                      className={`text-2xl transition-colors ${star <= rating ? "text-yellow-400" : "text-gray-600"}`}
                    >
                      ★
                    </button>
                  ))}
                </div>
                <ActionButton label={`Rate ${rating}/5`} action="rate" loading={actionLoading} onClick={() => execAction("rate")} color="yellow" />
              </div>
            )}

            {rated && (job.status === 2 || job.status === 5) && (
              <p className="text-sm text-gray-500">This job has already been rated.</p>
            )}
          </div>
        </div>
      )}
    </div>
  );
}

function ActionButton({
  label,
  action,
  loading,
  onClick,
  color,
}: {
  label: string;
  action: string;
  loading: string | null;
  onClick: () => void;
  color: string;
}) {
  const colors: Record<string, string> = {
    blue: "bg-blue-600 hover:bg-blue-700",
    green: "bg-green-600 hover:bg-green-700",
    red: "bg-red-600 hover:bg-red-700",
    orange: "bg-orange-600 hover:bg-orange-700",
    purple: "bg-purple-600 hover:bg-purple-700",
    yellow: "bg-yellow-600 hover:bg-yellow-700",
  };

  return (
    <button
      onClick={onClick}
      disabled={loading !== null}
      className={`px-4 py-2 ${colors[color] || colors.blue} disabled:bg-gray-700 disabled:text-gray-500 text-white rounded-lg text-sm font-medium transition-colors flex items-center gap-2`}
    >
      {loading === action ? <Spinner className="w-4 h-4" /> : null}
      {label}
    </button>
  );
}
