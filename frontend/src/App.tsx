import { useState, useEffect, useCallback } from "react";
import { BrowserProvider, formatEther } from "ethers";
import { POLYGON_CHAIN_ID, POLYGON_RPC } from "./contract";
import { useToasts } from "./hooks";
import Header from "./components/Header";
import Dashboard from "./components/Dashboard";
import CreateJob from "./components/CreateJob";
import JobViewer from "./components/JobViewer";
import ReputationLookup from "./components/ReputationLookup";
import ToastContainer from "./components/ToastContainer";

declare global {
  interface Window {
    ethereum?: any;
  }
}

export default function App() {
  const [account, setAccount] = useState<string | null>(null);
  const [balance, setBalance] = useState<string>("0");
  const [chainId, setChainId] = useState<string>("");
  const [provider, setProvider] = useState<BrowserProvider | null>(null);
  const [activeTab, setActiveTab] = useState<string>("dashboard");
  const { toasts, addToast, removeToast } = useToasts();

  const connectWallet = useCallback(async () => {
    if (!window.ethereum) {
      addToast("MetaMask not found. Please install it.", "error");
      return;
    }
    try {
      const p = new BrowserProvider(window.ethereum);
      const accounts: string[] = await p.send("eth_requestAccounts", []);
      const network = await p.getNetwork();
      const chainHex = "0x" + network.chainId.toString(16);

      if (chainHex !== POLYGON_CHAIN_ID) {
        try {
          await window.ethereum.request({
            method: "wallet_switchEthereumChain",
            params: [{ chainId: POLYGON_CHAIN_ID }],
          });
        } catch (switchErr: any) {
          if (switchErr.code === 4902) {
            await window.ethereum.request({
              method: "wallet_addEthereumChain",
              params: [{
                chainId: POLYGON_CHAIN_ID,
                chainName: "Polygon Mainnet",
                nativeCurrency: { name: "POL", symbol: "POL", decimals: 18 },
                rpcUrls: [POLYGON_RPC],
                blockExplorerUrls: ["https://polygonscan.com"],
              }],
            });
          } else {
            addToast("Please switch to Polygon network", "error");
            return;
          }
        }
        const p2 = new BrowserProvider(window.ethereum);
        setProvider(p2);
        const bal = await p2.getBalance(accounts[0]);
        setBalance(formatEther(bal));
        setChainId(POLYGON_CHAIN_ID);
      } else {
        setProvider(p);
        const bal = await p.getBalance(accounts[0]);
        setBalance(formatEther(bal));
        setChainId(chainHex);
      }

      setAccount(accounts[0]);
      addToast("Wallet connected!", "success");
    } catch (err: any) {
      addToast(err.message || "Failed to connect", "error");
    }
  }, [addToast]);

  useEffect(() => {
    if (!window.ethereum) return;
    const handleAccountsChanged = (accounts: string[]) => {
      if (accounts.length === 0) {
        setAccount(null);
        setProvider(null);
      } else {
        setAccount(accounts[0]);
        connectWallet();
      }
    };
    const handleChainChanged = () => {
      connectWallet();
    };
    window.ethereum.on("accountsChanged", handleAccountsChanged);
    window.ethereum.on("chainChanged", handleChainChanged);
    return () => {
      window.ethereum?.removeListener("accountsChanged", handleAccountsChanged);
      window.ethereum?.removeListener("chainChanged", handleChainChanged);
    };
  }, [connectWallet]);

  const tabs = [
    { id: "dashboard", label: "Dashboard" },
    { id: "create", label: "Create Job" },
    { id: "viewer", label: "Job Viewer" },
    { id: "reputation", label: "Reputation" },
  ];

  return (
    <div className="min-h-screen bg-[#0a0a0f]">
      <Header account={account} balance={balance} chainId={chainId} onConnect={connectWallet} />

      <div className="max-w-5xl mx-auto px-4 pb-12">
        <div className="flex gap-1 mb-8 bg-[#111118] rounded-xl p-1 overflow-x-auto">
          {tabs.map((t) => (
            <button
              key={t.id}
              onClick={() => setActiveTab(t.id)}
              className={`flex-1 px-4 py-2.5 rounded-lg text-sm font-medium transition-all whitespace-nowrap ${
                activeTab === t.id
                  ? "bg-blue-600 text-white shadow-lg shadow-blue-600/25"
                  : "text-gray-400 hover:text-gray-200 hover:bg-[#1a1a24]"
              }`}
            >
              {t.label}
            </button>
          ))}
        </div>

        {activeTab === "dashboard" && <Dashboard provider={provider} />}
        {activeTab === "create" && <CreateJob provider={provider} account={account} addToast={addToast} />}
        {activeTab === "viewer" && <JobViewer provider={provider} account={account} addToast={addToast} />}
        {activeTab === "reputation" && <ReputationLookup provider={provider} />}
      </div>

      <ToastContainer toasts={toasts} removeToast={removeToast} />
    </div>
  );
}
