//SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract Vault is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Errors ============
    error Vault__InvalidAPY();
    error Vault__ZeroAmount();
    error Vault__InsufficientBalance();
    error Vault__ZeroAddress();
    error Vault__TransferFailed();
    error Vault__NoDeposit();
    error Vault__Paused();
    error Vault__NotPaused();

    // ============ Events ============
    event Vault__APYUpdated(uint256 oldAPY, uint256 newAPY);
    event Vault__Deposit(address indexed user, uint256 amount, uint256 newBalance);
    event Vault__Withdraw(address indexed user, uint256 amount, uint256 remainingBalance);
    event Vault__EmergencyWithdraw(address indexed user, uint256 amount);
    event Vault__VaultPaused(address indexed by);
    event Vault__VaultUnpaused(address indexed by);

    // ============ State Variables ============
    IERC20 public immutable asset;
    uint256 public immutable baseRate; // Base APY in basis points (e.g., 200 = 2%)
    uint256 public immutable slope; // APY slope in basis points (e.g., 2000 = 20%)
    uint256 public immutable optimalDeposits; // Target deposit amount for max utilization
    
    uint256 private s_totalDeposits;
    bool private s_paused;

    mapping(address => uint256) private s_deposits;
    mapping(address => uint256) private s_depositTimestamp;

    // ============ Constants ============
    uint256 public constant MAX_APY = 10000; // 100% max APY
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant PRECISION = 1e18; // For safe math calculations

    // ============ Constructor ============
    constructor(
        address initialOwner,
        address _asset,
        uint256 _baseRate,
        uint256 _slope,
        uint256 _optimalDeposits
    ) Ownable(initialOwner) {
        if (_asset == address(0)) revert Vault__ZeroAddress();
        if (_baseRate > MAX_APY) revert Vault__InvalidAPY();
        if (_baseRate + _slope > MAX_APY) revert Vault__InvalidAPY();
        if (_optimalDeposits == 0) revert Vault__ZeroAmount();
        
        asset = IERC20(_asset);
        baseRate = _baseRate;
        slope = _slope;
        optimalDeposits = _optimalDeposits;
    }

    // ============ Modifiers ============
    modifier validAPY(uint256 _apy) {
        if (_apy == 0 || _apy > MAX_APY) revert Vault__InvalidAPY();
        _;
    }

    modifier validAmount(uint256 amount) {
        if (amount == 0) revert Vault__ZeroAmount();
        _;
    }

    modifier sufficientBalance(address user, uint256 amount) {
        if (s_deposits[user] < amount) revert Vault__InsufficientBalance();
        _;
    }

    modifier notZeroAddress(address user) {
        if (user == address(0)) revert Vault__ZeroAddress();
        _;
    }

    modifier whenNotPaused() {
        if (s_paused) revert Vault__Paused();
        _;
    }

    modifier whenPaused() {
        if (!s_paused) revert Vault__NotPaused();
        _;
    }

    // ============ External Functions ============

    /**
     * @notice Deposit tokens into the vault
     * @param amount Amount of tokens to deposit
     */
    function deposit(uint256 amount) 
        external 
        nonReentrant 
        whenNotPaused 
        validAmount(amount) 
    {
        uint256 oldAPY = _calculateAPY();
        
        asset.safeTransferFrom(msg.sender, address(this), amount);
        
        s_deposits[msg.sender] += amount;
        s_depositTimestamp[msg.sender] = block.timestamp;
        s_totalDeposits += amount;

        uint256 newAPY = _calculateAPY();
        emit Vault__Deposit(msg.sender, amount, s_deposits[msg.sender]);
        emit Vault__APYUpdated(oldAPY, newAPY);
    }

    /**
     * @notice Withdraw tokens from the vault
     * @param amount Amount of tokens to withdraw
     */
    function withdraw(uint256 amount) 
        external 
        nonReentrant 
        whenNotPaused 
        validAmount(amount) 
        sufficientBalance(msg.sender, amount) 
    {
        uint256 oldAPY = _calculateAPY();
        
        s_deposits[msg.sender] -= amount;
        s_totalDeposits -= amount;

        asset.safeTransfer(msg.sender, amount);

        uint256 newAPY = _calculateAPY();
        emit Vault__Withdraw(msg.sender, amount, s_deposits[msg.sender]);
        emit Vault__APYUpdated(oldAPY, newAPY);
    }

    /**
     * @notice Withdraw all tokens from the vault
     */
    function withdrawAll() external nonReentrant whenNotPaused {
        uint256 userBalance = s_deposits[msg.sender];
        if (userBalance == 0) revert Vault__NoDeposit();

        uint256 oldAPY = _calculateAPY();

        s_deposits[msg.sender] = 0;
        s_totalDeposits -= userBalance;

        asset.safeTransfer(msg.sender, userBalance);

        uint256 newAPY = _calculateAPY();
        emit Vault__Withdraw(msg.sender, userBalance, 0);
        emit Vault__APYUpdated(oldAPY, newAPY);
    }

    /**
     * @notice Emergency withdraw (available even when paused)
     */
    function emergencyWithdraw() external nonReentrant {
        uint256 userBalance = s_deposits[msg.sender];
        if (userBalance == 0) revert Vault__NoDeposit();

        s_deposits[msg.sender] = 0;
        s_totalDeposits -= userBalance;

        asset.safeTransfer(msg.sender, userBalance);

        emit Vault__EmergencyWithdraw(msg.sender, userBalance);
    }

    // ============ View Functions ============

    /**
     * @notice Calculate current APY based on utilization
     * @dev APY = baseRate + (utilization * slope)
     * @dev Utilization = totalDeposits / optimalDeposits (capped at 100%)
     * @return APY in basis points
     */
    function getAPY() external view returns (uint256) {
        return _calculateAPY();
    }

    /**
     * @notice Internal APY calculation with precision handling
     * @return APY in basis points
     */
    function _calculateAPY() internal view returns (uint256) {
        if (s_totalDeposits == 0) {
            return baseRate;
        }

        // Calculate utilization with precision: (totalDeposits * PRECISION) / optimalDeposits
        uint256 utilization = (s_totalDeposits * PRECISION) / optimalDeposits;
        
        // Cap utilization at 100% (PRECISION)
        if (utilization > PRECISION) {
            utilization = PRECISION;
        }

        // APY = baseRate + (utilization * slope) / PRECISION
        uint256 variableRate = (utilization * slope) / PRECISION;
        uint256 totalAPY = baseRate + variableRate;

        // Cap at MAX_APY
        if (totalAPY > MAX_APY) {
            totalAPY = MAX_APY;
        }

        return totalAPY;
    }

    /**
     * @notice Get current utilization rate
     * @return Utilization in basis points (10000 = 100%)
     */
    function getUtilization() external view returns (uint256) {
        if (s_totalDeposits == 0) {
            return 0;
        }
        
        uint256 utilization = (s_totalDeposits * BASIS_POINTS) / optimalDeposits;
        
        // Cap at 100%
        if (utilization > BASIS_POINTS) {
            utilization = BASIS_POINTS;
        }
        
        return utilization;
    }

    /**
     * @notice Get user's deposit balance
     * @param user Address of the user
     * @return User's deposited amount
     */
    function getDeposit(address user) external view returns (uint256) {
        return s_deposits[user];
    }

    /**
     * @notice Get user's deposit timestamp
     * @param user Address of the user
     * @return Timestamp of last deposit
     */
    function getDepositTimestamp(address user) external view returns (uint256) {
        return s_depositTimestamp[user];
    }

    /**
     * @notice Get total deposits in the vault
     * @return Total deposited amount
     */
    function getTotalDeposits() external view returns (uint256) {
        return s_totalDeposits;
    }

    /**
     * @notice Check if vault is paused
     * @return Paused status
     */
    function isPaused() external view returns (bool) {
        return s_paused;
    }

    /**
     * @notice Get vault's token balance
     * @return Token balance held by vault
     */
    function getVaultBalance() external view returns (uint256) {
        return asset.balanceOf(address(this));
    }
}