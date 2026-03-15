import { useState } from "react";
import { Contract, JsonRpcProvider, type BrowserProvider } from "ethers";
import { CONTRACT_ADDRESS, ESCROW_ABI, POLYGON_RPC } from "../contract";
import Spinner from "./Spinner";

interface Props {
  provider: BrowserProvider | null;
}

interface Stats {
  completedJobs: bigint;
  disputedJobs: bigint;
  avgRatingX100: bigint;
  ratingCount: bigint;
}

export default function ReputationLookup({ provider }: Props) {
  const [address, setAddress] = useState("");
  const [stats, setStats] = useState<Stats | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");

  const lookup = async () => {
    if (!address) return;
    try {
      setLoading(true);
      setError("");
      setStats(null);
      const p = provider || new JsonRpcProvider(POLYGON_RPC);
      const contract = new Contract(CONTRACT_ADDRESS, ESCROW_ABI, p);
      const [completed, disputed, avgX100, count] = await contract.sellerStats(address);
      setStats({
        completedJobs: completed,
        disputedJobs: disputed,
        avgRatingX100: avgX100,
        ratingCount: count,
      });
    } catch (err: any) {
      setError(err.reason || err.message || "Lookup failed");
    } finally {
      setLoading(false);
    }
  };

  const avgRating = stats ? Number(stats.avgRatingX100) / 100 : 0;
  const fullStars = Math.floor(avgRating);
  const hasHalf = avgRating - fullStars >= 0.25;

  return (
    <div className="space-y-4">
      <div className="bg-[#111118] border border-[#1e1e2e] rounded-xl p-5">
        <h2 className="text-lg font-semibold text-white mb-4">Seller Reputation Lookup</h2>
        <div className="flex gap-2">
          <input
            type="text"
            value={address}
            onChange={(e) => setAddress(e.target.value)}
            placeholder="Seller address (0x...)"
            className="flex-1 px-3 py-2.5 bg-[#0a0a0f] border border-[#1e1e2e] rounded-lg text-white text-sm font-mono focus:border-blue-500 focus:outline-none"
          />
          <button
            onClick={lookup}
            disabled={loading || !address}
            className="px-5 py-2.5 bg-blue-600 hover:bg-blue-700 disabled:bg-gray-700 text-white rounded-lg text-sm font-medium transition-colors flex items-center gap-2"
          >
            {loading ? <Spinner className="w-4 h-4" /> : "Lookup"}
          </button>
        </div>
        {error && <p className="text-red-400 text-sm mt-2">{error}</p>}
      </div>

      {stats && (
        <div className="bg-[#111118] border border-[#1e1e2e] rounded-xl p-6">
          <div className="text-center mb-6">
            <div className="text-4xl mb-2 flex justify-center gap-1">
              {[1, 2, 3, 4, 5].map((star) => (
                <span
                  key={star}
                  className={
                    star <= fullStars
                      ? "text-yellow-400"
                      : star === fullStars + 1 && hasHalf
                      ? "text-yellow-400/50"
                      : "text-gray-700"
                  }
                >
                  ★
                </span>
              ))}
            </div>
            <p className="text-2xl font-bold text-white">
              {Number(stats.ratingCount) > 0 ? avgRating.toFixed(2) : "No ratings"}
            </p>
            <p className="text-sm text-gray-500">
              {Number(stats.ratingCount)} rating{Number(stats.ratingCount) !== 1 ? "s" : ""}
            </p>
          </div>

          <div className="grid grid-cols-2 gap-4">
            <div className="bg-[#0a0a0f] rounded-lg p-4 text-center">
              <div className="text-2xl font-bold text-green-400">{stats.completedJobs.toString()}</div>
              <div className="text-xs text-gray-500 mt-1">Completed Jobs</div>
            </div>
            <div className="bg-[#0a0a0f] rounded-lg p-4 text-center">
              <div className="text-2xl font-bold text-orange-400">{stats.disputedJobs.toString()}</div>
              <div className="text-xs text-gray-500 mt-1">Disputed Jobs</div>
            </div>
          </div>

          {Number(stats.completedJobs) + Number(stats.disputedJobs) > 0 && (
            <div className="mt-4">
              <div className="flex justify-between text-xs text-gray-500 mb-1">
                <span>Success Rate</span>
                <span>
                  {(
                    (Number(stats.completedJobs) /
                      (Number(stats.completedJobs) + Number(stats.disputedJobs))) *
                    100
                  ).toFixed(1)}
                  %
                </span>
              </div>
              <div className="w-full bg-[#0a0a0f] rounded-full h-2">
                <div
                  className="bg-green-500 h-2 rounded-full transition-all"
                  style={{
                    width: `${
                      (Number(stats.completedJobs) /
                        (Number(stats.completedJobs) + Number(stats.disputedJobs))) *
                      100
                    }%`,
                  }}
                />
              </div>
            </div>
          )}
        </div>
      )}
    </div>
  );
}
