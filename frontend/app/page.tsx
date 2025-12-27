"use client";

import { useAccount, useConnect, useDisconnect, useReadContract, useWriteContract, useWaitForTransactionReceipt } from "wagmi";
import { ADDRESSES, AUTOMATION_VAULT_ABI, VAULT_ABI, ERC20_ABI } from "./contracts";
import { useState } from "react";
import { formatUnits, parseUnits } from "viem";

// Format number with commas
function formatNumber(value: bigint | undefined, decimals: number = 6): string {
  if (!value) return "0.00";
  const num = Number(formatUnits(value, decimals));
  return num.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

// Format APY from basis points
function formatAPY(bps: bigint | undefined): string {
  if (!bps) return "0.00";
  return (Number(bps) / 100).toFixed(2);
}

// Truncate address
function truncateAddress(address: string): string {
  return `${address.slice(0, 6)}...${address.slice(-4)}`;
}

export default function Home() {
  const { address, isConnected } = useAccount();
  const { connect, connectors } = useConnect();
  const { disconnect } = useDisconnect();
  const [depositAmount, setDepositAmount] = useState("");
  const [withdrawAmount, setWithdrawAmount] = useState("");
  const [activeTab, setActiveTab] = useState<"deposit" | "withdraw">("deposit");

  // Read contract data
  const { data: userBalance } = useReadContract({
    address: ADDRESSES.AUTOMATION_VAULT,
    abi: AUTOMATION_VAULT_ABI,
    functionName: "getUserBalance",
    args: address ? [address] : undefined,
    query: { enabled: !!address, refetchInterval: 5000 },
  });

  const { data: userShares } = useReadContract({
    address: ADDRESSES.AUTOMATION_VAULT,
    abi: AUTOMATION_VAULT_ABI,
    functionName: "userShares",
    args: address ? [address] : undefined,
    query: { enabled: !!address, refetchInterval: 5000 },
  });

  const { data: totalAssets } = useReadContract({
    address: ADDRESSES.AUTOMATION_VAULT,
    abi: AUTOMATION_VAULT_ABI,
    functionName: "getTotalAssets",
    query: { refetchInterval: 5000 },
  });

  const { data: allocationA } = useReadContract({
    address: ADDRESSES.AUTOMATION_VAULT,
    abi: AUTOMATION_VAULT_ABI,
    functionName: "allocationA",
    query: { refetchInterval: 5000 },
  });

  const { data: allocationB } = useReadContract({
    address: ADDRESSES.AUTOMATION_VAULT,
    abi: AUTOMATION_VAULT_ABI,
    functionName: "allocationB",
    query: { refetchInterval: 5000 },
  });

  const { data: lastApyA } = useReadContract({
    address: ADDRESSES.AUTOMATION_VAULT,
    abi: AUTOMATION_VAULT_ABI,
    functionName: "lastApyA",
    query: { refetchInterval: 5000 },
  });

  const { data: lastApyB } = useReadContract({
    address: ADDRESSES.AUTOMATION_VAULT,
    abi: AUTOMATION_VAULT_ABI,
    functionName: "lastApyB",
    query: { refetchInterval: 5000 },
  });

  const { data: vaultAAPY } = useReadContract({
    address: ADDRESSES.VAULT_A,
    abi: VAULT_ABI,
    functionName: "getAPY",
    query: { refetchInterval: 5000 },
  });

  const { data: vaultBAPY } = useReadContract({
    address: ADDRESSES.VAULT_B,
    abi: VAULT_ABI,
    functionName: "getAPY",
    query: { refetchInterval: 5000 },
  });

  const { data: usdcBalance } = useReadContract({
    address: ADDRESSES.USDC,
    abi: ERC20_ABI,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    query: { enabled: !!address, refetchInterval: 5000 },
  });

  const { data: allowance } = useReadContract({
    address: ADDRESSES.USDC,
    abi: ERC20_ABI,
    functionName: "allowance",
    args: address ? [address, ADDRESSES.AUTOMATION_VAULT] : undefined,
    query: { enabled: !!address, refetchInterval: 5000 },
  });

  // Write contract functions
  const { writeContract: approve, data: approveHash, isPending: isApproving } = useWriteContract();
  const { writeContract: deposit, data: depositHash, isPending: isDepositing } = useWriteContract();
  const { writeContract: withdraw, data: withdrawHash, isPending: isWithdrawing } = useWriteContract();

  const { isLoading: isApproveConfirming } = useWaitForTransactionReceipt({ hash: approveHash });
  const { isLoading: isDepositConfirming } = useWaitForTransactionReceipt({ hash: depositHash });
  const { isLoading: isWithdrawConfirming } = useWaitForTransactionReceipt({ hash: withdrawHash });

  const needsApproval = depositAmount && allowance !== undefined && 
    parseUnits(depositAmount || "0", 6) > allowance;

  const handleApprove = () => {
    approve({
      address: ADDRESSES.USDC,
      abi: ERC20_ABI,
      functionName: "approve",
      args: [ADDRESSES.AUTOMATION_VAULT, parseUnits("1000000", 6)],
    });
  };

  const handleDeposit = () => {
    if (!depositAmount) return;
    deposit({
      address: ADDRESSES.AUTOMATION_VAULT,
      abi: AUTOMATION_VAULT_ABI,
      functionName: "deposit",
      args: [parseUnits(depositAmount, 6)],
    });
  };

  const handleWithdraw = () => {
    if (!withdrawAmount || !userShares) return;
    const sharesToWithdraw = (parseUnits(withdrawAmount, 6) * userShares) / (userBalance || BigInt(1));
    withdraw({
      address: ADDRESSES.AUTOMATION_VAULT,
      abi: AUTOMATION_VAULT_ABI,
      functionName: "withdraw",
      args: [sharesToWithdraw],
    });
  };

  const isLoading = isApproving || isDepositing || isWithdrawing || isApproveConfirming || isDepositConfirming || isWithdrawConfirming;

  // Calculate effective APY (weighted average based on allocations)
  const effectiveAPY = (() => {
    const a = allocationA || BigInt(0);
    const b = allocationB || BigInt(0);
    const total = a + b;
    if (total === BigInt(0)) return lastApyB || vaultBAPY || BigInt(0);
    const apyA = lastApyA || vaultAAPY || BigInt(0);
    const apyB = lastApyB || vaultBAPY || BigInt(0);
    return (apyA * a + apyB * b) / total;
  })();

  return (
    <div className="min-h-screen bg-[var(--background)]">
      {/* Header */}
      <header className="border-b border-[var(--border)]">
        <div className="mx-auto max-w-6xl px-6 py-4 flex items-center justify-between">
          <div className="flex items-center gap-2">
            <div className="w-8 h-8 rounded-full bg-[var(--foreground)] flex items-center justify-center">
              <span className="text-[var(--background)] text-sm font-bold">V</span>
            </div>
            <span className="font-semibold text-lg">Vaultus</span>
          </div>
          
          {isConnected ? (
            <button
              onClick={() => disconnect()}
              className="px-4 py-2 text-sm border border-[var(--border)] rounded-lg hover:bg-[var(--card)] transition-colors"
            >
              {truncateAddress(address!)}
            </button>
          ) : (
            <button
              onClick={() => connect({ connector: connectors[0] })}
              className="px-4 py-2 text-sm bg-[var(--foreground)] text-[var(--background)] rounded-lg hover:opacity-90 transition-opacity"
            >
              Connect Wallet
            </button>
          )}
        </div>
      </header>

      <main className="mx-auto max-w-6xl px-6 py-12">
        {/* Hero */}
        <div className="mb-12">
          <h1 className="text-4xl font-bold mb-3">Cross-Chain Lending Automation</h1>
          <p className="text-[var(--muted)] text-lg max-w-2xl">
            Deposit once, earn optimized yields. The vault automatically rebalances between lending pools using Reactive Network.
          </p>
        </div>

        {/* Stats Grid */}
        <div className="grid grid-cols-1 md:grid-cols-4 gap-4 mb-8">
          <div className="p-5 border border-[var(--border)] rounded-xl">
            <p className="text-[var(--muted)] text-sm mb-1">Total Value Locked</p>
            <p className="text-2xl font-semibold">${formatNumber(totalAssets)}</p>
          </div>
          <div className="p-5 border border-[var(--border)] rounded-xl">
            <p className="text-[var(--muted)] text-sm mb-1">Effective APY</p>
            <p className="text-2xl font-semibold">{formatAPY(effectiveAPY)}%</p>
          </div>
          <div className="p-5 border border-[var(--border)] rounded-xl">
            <p className="text-[var(--muted)] text-sm mb-1">Pool A APY</p>
            <p className="text-2xl font-semibold">{formatAPY(vaultAAPY)}%</p>
          </div>
          <div className="p-5 border border-[var(--border)] rounded-xl">
            <p className="text-[var(--muted)] text-sm mb-1">Pool B APY</p>
            <p className="text-2xl font-semibold">{formatAPY(vaultBAPY)}%</p>
          </div>
        </div>

        <div className="grid grid-cols-1 lg:grid-cols-3 gap-8">
          {/* Main Action Card */}
          <div className="lg:col-span-2">
            <div className="border border-[var(--border)] rounded-xl overflow-hidden">
              {/* Tabs */}
              <div className="flex border-b border-[var(--border)]">
                <button
                  onClick={() => setActiveTab("deposit")}
                  className={`flex-1 py-4 text-center font-medium transition-colors ${
                    activeTab === "deposit"
                      ? "bg-[var(--card)]"
                      : "text-[var(--muted)] hover:text-[var(--foreground)]"
                  }`}
                >
                  Deposit
                </button>
                <button
                  onClick={() => setActiveTab("withdraw")}
                  className={`flex-1 py-4 text-center font-medium transition-colors ${
                    activeTab === "withdraw"
                      ? "bg-[var(--card)]"
                      : "text-[var(--muted)] hover:text-[var(--foreground)]"
                  }`}
                >
                  Withdraw
                </button>
              </div>

              <div className="p-6">
                {activeTab === "deposit" ? (
                  <div className="space-y-4">
                    <div>
                      <div className="flex justify-between mb-2">
                        <label className="text-sm text-[var(--muted)]">Amount</label>
                        <span className="text-sm text-[var(--muted)]">
                          Balance: {formatNumber(usdcBalance)} USDC
                        </span>
                      </div>
                      <div className="flex border border-[var(--border)] rounded-lg overflow-hidden focus-within:border-[var(--foreground)] transition-colors">
                        <input
                          type="number"
                          placeholder="0.00"
                          value={depositAmount}
                          onChange={(e) => setDepositAmount(e.target.value)}
                          className="flex-1 px-4 py-3 bg-transparent outline-none text-lg"
                        />
                        <button
                          onClick={() => setDepositAmount(formatUnits(usdcBalance || BigInt(0), 6))}
                          className="px-4 text-sm text-[var(--muted)] hover:text-[var(--foreground)] transition-colors"
                        >
                          MAX
                        </button>
                        <div className="px-4 py-3 bg-[var(--card)] border-l border-[var(--border)] font-medium">
                          USDC
                        </div>
                      </div>
                    </div>

                    {isConnected ? (
                      needsApproval ? (
                        <button
                          onClick={handleApprove}
                          disabled={isLoading}
                          className="w-full py-4 bg-[var(--foreground)] text-[var(--background)] rounded-lg font-medium hover:opacity-90 transition-opacity disabled:opacity-50"
                        >
                          {isLoading ? "Approving..." : "Approve USDC"}
                        </button>
                      ) : (
                        <button
                          onClick={handleDeposit}
                          disabled={isLoading || !depositAmount}
                          className="w-full py-4 bg-[var(--foreground)] text-[var(--background)] rounded-lg font-medium hover:opacity-90 transition-opacity disabled:opacity-50"
                        >
                          {isLoading ? "Depositing..." : "Deposit"}
                        </button>
                      )
                    ) : (
                      <button
                        onClick={() => connect({ connector: connectors[0] })}
                        className="w-full py-4 bg-[var(--foreground)] text-[var(--background)] rounded-lg font-medium hover:opacity-90 transition-opacity"
                      >
                        Connect Wallet
                      </button>
                    )}
                  </div>
                ) : (
                  <div className="space-y-4">
                    <div>
                      <div className="flex justify-between mb-2">
                        <label className="text-sm text-[var(--muted)]">Amount</label>
                        <span className="text-sm text-[var(--muted)]">
                          Deposited: {formatNumber(userBalance)} USDC
                        </span>
                      </div>
                      <div className="flex border border-[var(--border)] rounded-lg overflow-hidden focus-within:border-[var(--foreground)] transition-colors">
                        <input
                          type="number"
                          placeholder="0.00"
                          value={withdrawAmount}
                          onChange={(e) => setWithdrawAmount(e.target.value)}
                          className="flex-1 px-4 py-3 bg-transparent outline-none text-lg"
                        />
                        <button
                          onClick={() => setWithdrawAmount(formatUnits(userBalance || BigInt(0), 6))}
                          className="px-4 text-sm text-[var(--muted)] hover:text-[var(--foreground)] transition-colors"
                        >
                          MAX
                        </button>
                        <div className="px-4 py-3 bg-[var(--card)] border-l border-[var(--border)] font-medium">
                          USDC
                        </div>
                      </div>
                    </div>

                    {isConnected ? (
                      <button
                        onClick={handleWithdraw}
                        disabled={isLoading || !withdrawAmount}
                        className="w-full py-4 bg-[var(--foreground)] text-[var(--background)] rounded-lg font-medium hover:opacity-90 transition-opacity disabled:opacity-50"
                      >
                        {isLoading ? "Withdrawing..." : "Withdraw"}
                      </button>
                    ) : (
                      <button
                        onClick={() => connect({ connector: connectors[0] })}
                        className="w-full py-4 bg-[var(--foreground)] text-[var(--background)] rounded-lg font-medium hover:opacity-90 transition-opacity"
                      >
                        Connect Wallet
                      </button>
                    )}
                  </div>
                )}
              </div>
            </div>
          </div>

          {/* Sidebar */}
          <div className="space-y-4">
            {/* Your Position */}
            <div className="border border-[var(--border)] rounded-xl p-5">
              <h3 className="font-semibold mb-4">Your Position</h3>
              <div className="space-y-3">
                <div className="flex justify-between">
                  <span className="text-[var(--muted)]">Deposited</span>
                  <span className="font-medium">${formatNumber(userBalance)}</span>
                </div>
                <div className="flex justify-between">
                  <span className="text-[var(--muted)]">Shares</span>
                  <span className="font-medium font-mono text-sm">
                    {userShares ? formatUnits(userShares, 18).slice(0, 10) : "0"}
                  </span>
                </div>
              </div>
            </div>

            {/* Allocation */}
            <div className="border border-[var(--border)] rounded-xl p-5">
              <h3 className="font-semibold mb-4">Current Allocation</h3>
              <div className="space-y-3">
                <div>
                  <div className="flex justify-between mb-2">
                    <span className="text-[var(--muted)]">Pool A</span>
                    <span className="font-medium">${formatNumber(allocationA)}</span>
                  </div>
                  <div className="h-2 bg-[var(--card)] rounded-full overflow-hidden">
                    <div 
                      className="h-full bg-[var(--foreground)] transition-all duration-500"
                      style={{ 
                        width: `${totalAssets && totalAssets > BigInt(0) 
                          ? Number((allocationA || BigInt(0)) * BigInt(100) / totalAssets) 
                          : 0}%` 
                      }}
                    />
                  </div>
                </div>
                <div>
                  <div className="flex justify-between mb-2">
                    <span className="text-[var(--muted)]">Pool B</span>
                    <span className="font-medium">${formatNumber(allocationB)}</span>
                  </div>
                  <div className="h-2 bg-[var(--card)] rounded-full overflow-hidden">
                    <div 
                      className="h-full bg-[var(--foreground)] transition-all duration-500"
                      style={{ 
                        width: `${totalAssets && totalAssets > BigInt(0) 
                          ? Number((allocationB || BigInt(0)) * BigInt(100) / totalAssets) 
                          : 0}%` 
                      }}
                    />
                  </div>
                </div>
              </div>
            </div>

            {/* How it works */}
            <div className="border border-[var(--border)] rounded-xl p-5">
              <h3 className="font-semibold mb-4">How it works</h3>
              <ol className="space-y-3 text-sm text-[var(--muted)]">
                <li className="flex gap-3">
                  <span className="flex-shrink-0 w-5 h-5 rounded-full border border-[var(--border)] flex items-center justify-center text-xs">1</span>
                  <span>Deposit USDC into the vault</span>
                </li>
                <li className="flex gap-3">
                  <span className="flex-shrink-0 w-5 h-5 rounded-full border border-[var(--border)] flex items-center justify-center text-xs">2</span>
                  <span>Vault allocates to highest APY pool</span>
                </li>
                <li className="flex gap-3">
                  <span className="flex-shrink-0 w-5 h-5 rounded-full border border-[var(--border)] flex items-center justify-center text-xs">3</span>
                  <span>Reactive Network monitors APY changes</span>
                </li>
                <li className="flex gap-3">
                  <span className="flex-shrink-0 w-5 h-5 rounded-full border border-[var(--border)] flex items-center justify-center text-xs">4</span>
                  <span>Auto-rebalances when better rates found</span>
                </li>
              </ol>
            </div>
          </div>
        </div>

        {/* Contracts Section */}
        <div className="mt-12 pt-8 border-t border-[var(--border)]">
          <h2 className="text-lg font-semibold mb-4">Contract Addresses</h2>
          <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4">
            {[
              { label: "Automation Vault", address: ADDRESSES.AUTOMATION_VAULT },
              { label: "Vault A", address: ADDRESSES.VAULT_A },
              { label: "Vault B", address: ADDRESSES.VAULT_B },
              { label: "Vaultus", address: ADDRESSES.REACTIVE_VAULT },
            ].map((item) => (
              <div key={item.label} className="p-4 bg-[var(--card)] rounded-lg">
                <p className="text-sm text-[var(--muted)] mb-1">{item.label}</p>
                <a
                  href={`https://sepolia.etherscan.io/address/${item.address}`}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="font-mono text-sm hover:underline"
                >
                  {truncateAddress(item.address)}
                </a>
              </div>
            ))}
          </div>
        </div>
      </main>
    </div>
  );
}
