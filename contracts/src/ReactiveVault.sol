// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { AbstractReactive } from "reactive-lib/abstract-base/AbstractReactive.sol";
import { IReactive } from "reactive-lib/interfaces/IReactive.sol";
import { ISystemContract } from "reactive-lib/interfaces/ISystemContract.sol";
import { AbstractPayer } from "reactive-lib/abstract-base/AbstractPayer.sol";
import { IPayer } from "reactive-lib/interfaces/IPayer.sol";

/**
 * @title ReactiveVault
 * @notice Reactive contract that monitors APY changes on multiple vaults and triggers rebalancing
 * @dev Deployed on Reactive Network (Lasna Testnet), listens to events from origin chains
 * 
 * Architecture:
 * - This contract runs on Reactive Network
 * - Subscribes to Vault__APYUpdated events from Vault A and Vault B
 * - When APY difference exceeds threshold, emits Callback to trigger rebalance
 * - Callback is sent to AutomationVault on destination chain
 */
contract ReactiveVault is AbstractReactive {
    // ============ Constants ============
    
    // Event signature: keccak256("Vault__APYUpdated(uint256,uint256)")
    uint256 private constant APY_UPDATED_TOPIC = 0xab8a0c1bf4afdaf4b3ca26368058b020a0298692e69bd8300613ae6712b3ea2d;
    
    // Gas limit for callbacks
    uint64 private constant CALLBACK_GAS_LIMIT = 1_000_000;

    // ============ State Variables ============
    
    // Chain configuration
    uint256 public immutable originChainId;
    uint256 public immutable destinationChainId;
    
    // Vault addresses on origin chain
    address public immutable vaultA;
    address public immutable vaultB;
    
    // Automation contract on destination chain (receives callbacks)
    address public immutable automationVault;
    
    // Rebalancing configuration
    uint256 public rebalanceThreshold; // Minimum APY difference to trigger rebalance (in basis points)
    
    // Track latest APYs
    uint256 public lastApyA;
    uint256 public lastApyB;
    uint256 public lastRebalanceBlock;
    
    // Owner
    address public owner;

    // ============ Events ============
    
    event APYReceived(address indexed vault, uint256 oldApy, uint256 newApy);
    event RebalanceTriggered(address indexed fromVault, address indexed toVault, uint256 apyDifference);
    event ThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);

    // ============ Errors ============
    
    error OnlyOwner();
    error InvalidThreshold();

    // ============ Modifiers ============
    
    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    // ============ Constructor ============
    
    /**
     * @param _service System contract address on Reactive Network (0x0000000000000000000000000000000000fffFfF)
     * @param _originChainId Chain ID where vaults are deployed (e.g., Sepolia = 11155111)
     * @param _destinationChainId Chain ID for callbacks (e.g., Sepolia = 11155111)
     * @param _vaultA Address of first vault on origin chain
     * @param _vaultB Address of second vault on origin chain
     * @param _automationVault Address of automation contract on destination chain
     * @param _rebalanceThreshold Minimum APY difference to trigger rebalance (basis points)
     */
    constructor(
        address _service,
        uint256 _originChainId,
        uint256 _destinationChainId,
        address _vaultA,
        address _vaultB,
        address _automationVault,
        uint256 _rebalanceThreshold
    ) payable {
        service = ISystemContract(payable(_service));
        
        owner = msg.sender;
        
        originChainId = _originChainId;
        destinationChainId = _destinationChainId;
        vaultA = _vaultA;
        vaultB = _vaultB;
        automationVault = _automationVault;
        rebalanceThreshold = _rebalanceThreshold;

        // Subscribe to events only when deployed on Reactive Network (not in ReactVM)
        if (!vm) {
            // Subscribe to APY updates from Vault A
            service.subscribe(
                _originChainId,
                _vaultA,
                APY_UPDATED_TOPIC,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );

            // Subscribe to APY updates from Vault B
            service.subscribe(
                _originChainId,
                _vaultB,
                APY_UPDATED_TOPIC,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        }
    }

    // ============ Reactive Function ============
    
    /**
     * @notice Called by Reactive Network when a subscribed event is detected
     * @dev ReactVM is stateless, so we always emit callback with APY data
     *      AutomationVault on Sepolia will track state and decide on rebalancing
     * @param log The event log data
     */
    function react(LogRecord calldata log) external vmOnly {
        // Decode APY data from event
        // Event: Vault__APYUpdated(uint256 oldAPY, uint256 newAPY)
        (uint256 oldApy, uint256 newApy) = abi.decode(log.data, (uint256, uint256));
        
        // Emit event for tracking (in ReactVM only)
        emit APYReceived(log._contract, oldApy, newApy);

        // Always emit callback with APY data - let AutomationVault on Sepolia handle logic
        // ReactVM is stateless, so we can't track state here
        bytes memory payload = abi.encodeWithSignature(
            "updateAPY(address,address,uint256)",
            address(0), // Will be replaced with RVM ID by Reactive Network
            log._contract, // Which vault emitted the event (vaultA or vaultB)
            newApy // The new APY value
        );

        emit Callback(destinationChainId, automationVault, CALLBACK_GAS_LIMIT, payload);
    }

    // ============ Owner Functions ============
    
    /**
     * @notice Update rebalance threshold
     * @param _newThreshold New threshold in basis points
     */
    function setRebalanceThreshold(uint256 _newThreshold) external onlyOwner {
        if (_newThreshold == 0 || _newThreshold > 5000) revert InvalidThreshold(); // Max 50%
        
        uint256 oldThreshold = rebalanceThreshold;
        rebalanceThreshold = _newThreshold;
        
        emit ThresholdUpdated(oldThreshold, _newThreshold);
    }

    /**
     * @notice Pause subscriptions
     */
    function pause() external rnOnly onlyOwner {
        service.unsubscribe(
            originChainId,
            vaultA,
            APY_UPDATED_TOPIC,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        
        service.unsubscribe(
            originChainId,
            vaultB,
            APY_UPDATED_TOPIC,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
    }

    /**
     * @notice Resume subscriptions
     */
    function resume() external rnOnly onlyOwner {
        service.subscribe(
            originChainId,
            vaultA,
            APY_UPDATED_TOPIC,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        
        service.subscribe(
            originChainId,
            vaultB,
            APY_UPDATED_TOPIC,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
    }

    // ============ View Functions ============
    
    /**
     * @notice Get current APY difference between vaults
     */
    function getApyDifference() external view returns (uint256) {
        if (lastApyA > lastApyB) {
            return lastApyA - lastApyB;
        }
        return lastApyB - lastApyA;
    }

    /**
     * @notice Check if rebalance would be triggered with current APYs
     */
    function shouldRebalance() external view returns (bool) {
        if (lastApyA == 0 || lastApyB == 0) return false;
        
        uint256 diff = lastApyA > lastApyB ? lastApyA - lastApyB : lastApyB - lastApyA;
        return diff >= rebalanceThreshold;
    }

    /**
     * @notice Get the vault with higher APY
     */
    function getHigherApyVault() external view returns (address vault, uint256 apy) {
        if (lastApyA >= lastApyB) {
            return (vaultA, lastApyA);
        }
        return (vaultB, lastApyB);
    }

    // ============ Receive ============
    
    receive() external payable override(AbstractPayer, IPayer) {}
}
