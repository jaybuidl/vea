// SPDX-License-Identifier: MIT

/**
 *  @authors: [@jaybuidl, @shotaronowhere]
 *  @reviewers: []
 *  @auditors: []
 *  @bounties: []
 *  @deployments: []
 */

pragma solidity 0.8.18;

import "../canonical/gnosis-chain/IAMB.sol";
import "./interfaces/IVeaOutboxArbToGnosis.sol";

/**
 * Vea Bridge Outbox From Arbitrum to Gnosis.
 */
contract VeaOutboxArbToGnosis is IVeaOutboxArbToGnosis {
    IAMB public immutable amb; // The address of the AMB contract on Gnosis.
    address public immutable router; // The address of the router from Arbitrum to Gnosis on ethereum.

    uint256 public immutable deposit; // The deposit required to submit a claim or challenge
    uint256 internal immutable burn; // The amount of wei to burn. deposit / 2
    uint256 internal immutable depositPlusReward; // 2 * deposit - burn
    address internal constant burnAddress = address(0x0000000000000000000000000000000000000000);

    uint256 internal constant slotTime = 5; // Gnosis 5 second slot time

    uint256 public immutable epochPeriod; // Epochs mark the period between potential snapshots.
    uint256 public immutable challengePeriod; // Claim challenge timewindow.
    uint256 public immutable claimDelay; // Can only claim for epochs after this delay. eg 1 => claims about epoch 1 can be made in epoch 2.

    uint256 public immutable timeoutEpochs; // The number of epochs without forward progress before the bridge is considered shutdown.
    uint256 public immutable maxMissingBlocks; // The maximum number of blocks that can be missing in a challenge period.

    bytes32 public stateRoot;
    uint256 public latestVerifiedEpoch;

    mapping(uint256 => bytes32) public claimHashes; // epoch => claim
    mapping(uint256 => bytes32) public relayed; // msgId/256 => packed replay bitmap

    /**
     * @dev Watcher check this event to challenge fraud.
     * @param claimer The address of the claimer.
     * @param stateRoot The state root of the challenged claim.
     */
    event Claimed(address indexed claimer, bytes32 stateRoot);

    /**
     * @dev This event indicates that `sendSnapshot(epoch)` should be called in the inbox.
     * @param epoch The epoch associated with the challenged claim.
     * @param challenger The address of the challenger.
     */
    event Challenged(uint256 epoch, address indexed challenger);

    /**
     * @dev This event indicates that a message has been relayed.
     * @param msgId The msgId of the message that was relayed.
     */
    event MessageRelayed(uint64 msgId);

    /**
     * @dev This events indicates that verification has succeeded. The messages are ready to be relayed.
     * @param epoch The epoch that was verified.
     */
    event Verified(uint256 epoch);

    modifier OnlyBridgeRunning() {
        unchecked {
            require(block.timestamp / epochPeriod <= latestVerifiedEpoch + timeoutEpochs, "Bridge Shutdown.");
        }
        _;
    }

    modifier OnlyBridgeShutdown() {
        unchecked {
            require(latestVerifiedEpoch + timeoutEpochs < block.timestamp / epochPeriod, "Bridge Running.");
        }
        _;
    }

    /**
     * @dev Constructor.
     * @param _deposit The deposit amount to submit a claim in wei.
     * @param _epochPeriod The duration of each epoch.
     * @param _challengePeriod The duration of the period allowing to challenge a claim.
     * @param _timeoutEpochs The epochs before the bridge is considered shutdown.
     * @param _claimDelay The number of epochs a claim can be submitted for.
     * @param _amb The address of the AMB contract on Gnosis.
     * @param _router The address of the challenge resolver router contract on Ethereum.
     * @param _maxMissingBlocks The maximum number of blocks that can be missing in a challenge period.
     */
    constructor(
        uint256 _deposit,
        uint256 _epochPeriod,
        uint256 _challengePeriod,
        uint256 _timeoutEpochs,
        uint256 _claimDelay,
        IAMB _amb,
        address _router,
        uint256 _maxMissingBlocks
    ) {
        deposit = _deposit;
        epochPeriod = _epochPeriod;
        challengePeriod = _challengePeriod;
        timeoutEpochs = _timeoutEpochs;
        claimDelay = _claimDelay;
        amb = _amb;
        router = _router;
        maxMissingBlocks = _maxMissingBlocks;

        // claimant and challenger are not sybil resistant
        // must burn half deposit to prevent zero cost griefing
        burn = _deposit / 2;
        depositPlusReward = 2 * _deposit - burn;

        latestVerifiedEpoch = block.timestamp / epochPeriod - 1;

        require(claimDelay <= block.timestamp, "Invalid epochClaimDelay.");
    }

    // ************************************* //
    // *         State Modifiers           * //
    // ************************************* //

    /**
     * @dev Submit a claim about the the _stateRoot at _epoch and submit a deposit.
     * @param _epoch The epoch for which the claim is made.
     * @param _stateRoot The state root to claim.
     */
    function claim(uint256 _epoch, bytes32 _stateRoot) external payable virtual {
        require(msg.value >= deposit, "Insufficient claim deposit.");

        unchecked {
            require((block.timestamp - claimDelay) / epochPeriod == _epoch, "Invalid epoch.");
        }

        require(_stateRoot != bytes32(0), "Invalid claim.");
        require(claimHashes[_epoch] == bytes32(0), "Claim already made.");

        claimHashes[_epoch] = hashClaim(
            Claim({
                stateRoot: _stateRoot,
                claimer: msg.sender,
                timestamp: uint32(block.timestamp),
                blocknumber: uint32(block.number),
                honest: Party.None,
                challenger: address(0)
            })
        );

        emit Claimed(msg.sender, _stateRoot);
    }

    /**
     * @dev Submit a challenge for the claim of the inbox state root snapshot taken at 'epoch'.
     * @param epoch The epoch of the claim to challenge.
     */
    function challenge(uint256 epoch, Claim memory claim) external payable virtual {
        require(claimHashes[epoch] == hashClaim(claim), "Invalid claim.");
        require(claim.challenger == address(0), "Claim already challenged.");
        require(msg.value >= deposit, "Insufficient challenge deposit.");

        unchecked {
            require(block.timestamp < uint256(claim.timestamp) + challengePeriod, "Challenge period elapsed.");
        }

        claim.challenger = msg.sender;
        claimHashes[epoch] = hashClaim(claim);

        emit Challenged(epoch, msg.sender);
    }

    /**
     * @dev Resolves the optimistic claim for '_epoch'.
     * @param epoch The epoch of the optimistic claim.
     */
    function validateSnapshot(uint256 epoch, Claim memory claim) external OnlyBridgeRunning {
        require(claimHashes[epoch] == hashClaim(claim), "Invalid claim.");

        unchecked {
            require(claim.timestamp + challengePeriod < block.timestamp, "Challenge period has not yet elapsed.");
            require(
                // expected blocks <= actual blocks + maxMissingBlocks
                uint256(claim.blocknumber) + (block.timestamp - uint256(claim.timestamp)) / slotTime <=
                    block.number + maxMissingBlocks,
                "Too many missing blocks. Possible censorship attack. Use canonical bridge."
            );
        }

        require(claim.challenger == address(0), "Claim is challenged.");

        if (epoch > latestVerifiedEpoch) {
            latestVerifiedEpoch = epoch;
            stateRoot = claim.stateRoot;
            emit Verified(epoch);
        }

        claim.honest = Party.Claimer;
        claimHashes[epoch] = hashClaim(claim);
    }

    /**
     * Note: Access restricted to arbitrum  bridge.
     * @dev Resolves any challenge of the optimistic claim for '_epoch'.
     * @param epoch The epoch to verify.
     * @param _stateRoot The true state root for the epoch.
     */
    function resolveDisputedClaim(
        uint256 epoch,
        bytes32 _stateRoot,
        Claim memory claim
    ) external virtual OnlyBridgeRunning {
        require(msg.sender == address(amb), "Not from bridge.");
        require(amb.messageSender() == router, "Not from router.");

        if (epoch > latestVerifiedEpoch && _stateRoot != bytes32(0)) {
            latestVerifiedEpoch = epoch;
            stateRoot = _stateRoot;
            emit Verified(epoch);
        }

        if (claimHashes[epoch] == hashClaim(claim) && claim.honest == Party.None) {
            if (claim.stateRoot == _stateRoot) {
                claim.honest = Party.Claimer;
            } else if (claim.challenger != address(0)) {
                claim.honest = Party.Challenger;
            }
            claimHashes[epoch] = hashClaim(claim);
        }
    }

    /**
     * @dev Verifies and relays the message. UNTRUSTED.
     * @param proof The merkle proof to prove the message.
     * @param msgId The zero based index of the message in the inbox.
     * @param to The address of the contract on the receiving chain which receives the calldata.
     * @param message The message encoded with header from VeaInbox.
     */
    function sendMessage(bytes32[] calldata proof, uint64 msgId, address to, bytes calldata message) external {
        require(proof.length < 64, "Proof too long.");

        bytes32 nodeHash = keccak256(abi.encodePacked(msgId, to, message));

        // double hashed leaf
        // avoids second order preimage attacks
        // https://flawed.net.nz/2018/02/21/attacking-merkle-trees-with-a-second-preimage-attack/
        assembly {
            mstore(0x00, nodeHash)
            nodeHash := keccak256(0x00, 0x20)
        }

        unchecked {
            for (uint256 i = 0; i < proof.length; i++) {
                bytes32 proofElement = proof[i];
                // sort sibling hashes as a convention for efficient proof validation
                if (proofElement > nodeHash)
                    assembly {
                        mstore(0x00, nodeHash)
                        mstore(0x20, proofElement)
                        nodeHash := keccak256(0x00, 0x40)
                    }
                else
                    assembly {
                        mstore(0x00, proofElement)
                        mstore(0x20, nodeHash)
                        nodeHash := keccak256(0x00, 0x40)
                    }
            }
        }

        require(stateRoot == nodeHash, "Invalid proof.");

        // msgId is the zero based index of the message in the inbox and is the same index to prevent replay

        uint256 relayIndex = msgId >> 8;
        uint256 offset;

        unchecked {
            offset = msgId % 256;
        }

        bytes32 replay = relayed[relayIndex];

        require(((replay >> offset) & bytes32(uint256(1))) == bytes32(0), "Message already relayed");
        relayed[relayIndex] = replay | bytes32(1 << offset);

        // UNTRUSTED.
        (bool success, ) = to.call(message);
        require(success, "Failed to call contract");

        emit MessageRelayed(msgId);
    }

    /**
     * @dev Sends the deposit back to the Bridger if their claim is not successfully challenged. Includes a portion of the Challenger's deposit if unsuccessfully challenged.
     * @param epoch The epoch associated with the claim deposit to withraw.
     */
    function withdrawClaimDeposit(uint256 epoch, Claim calldata claim) external {
        require(claimHashes[epoch] == hashClaim(claim), "Invalid claim.");
        require(claim.honest == Party.Claimer, "Claim failed.");

        delete claimHashes[epoch];

        if (claim.challenger != address(0)) {
            payable(burnAddress).send(burn);
            payable(claim.claimer).send(depositPlusReward); // User is responsibility for accepting ETH.
        } else {
            payable(claim.claimer).send(deposit); // User is responsibility for accepting ETH.
        }
    }

    /**
     * @dev Sends the deposit back to the Challenger if their challenge is successful. Includes a portion of the Bridger's deposit.
     * @param epoch The epoch associated with the challenge deposit to withraw.
     */
    function withdrawChallengeDeposit(uint256 epoch, Claim calldata claim) external {
        require(claimHashes[epoch] == hashClaim(claim), "Invalid claim.");
        require(claim.honest == Party.Challenger, "Challenge failed.");

        delete claimHashes[epoch];

        payable(burnAddress).send(burn); // half burnt
        payable(claim.challenger).send(depositPlusReward); // User is responsibility for accepting ETH.
    }

    /**
     * @dev When bridge is shutdown, no claim disputes can be resolved. This allows the claimer to withdraw their deposit.
     * @param epoch The epoch associated with the claim deposit to withraw.
     */
    function withdrawClaimerEscapeHatch(uint256 epoch, Claim memory claim) external OnlyBridgeShutdown {
        require(claimHashes[epoch] == hashClaim(claim), "Invalid claim.");
        require(claim.honest == Party.None, "Claim resolved.");

        if (claim.claimer != address(0)) {
            if (claim.challenger == address(0)) {
                delete claimHashes[epoch];
            } else {
                claim.claimer = address(0);
                claimHashes[epoch] == hashClaim(claim);
            }
            payable(claim.claimer).send(deposit); // User is responsibility for accepting ETH.
        }
    }

    /**
     * @dev When bridge is shutdown, no claim disputes can be resolved. This allows the claimer to withdraw their deposit.
     * @param epoch The epoch associated with the claim deposit to withraw.
     */
    function withdrawChallengerEscapeHatch(uint256 epoch, Claim memory claim) external OnlyBridgeShutdown {
        require(claimHashes[epoch] == hashClaim(claim), "Invalid claim.");
        require(claim.honest == Party.None, "Claim resolved.");

        if (claim.challenger != address(0)) {
            if (claim.claimer == address(0)) {
                delete claimHashes[epoch];
            } else {
                claim.challenger = address(0);
                claimHashes[epoch] == hashClaim(claim);
            }
            payable(claim.challenger).send(deposit); // User is responsibility for accepting ETH.
        }
    }

    function hashClaim(Claim memory claim) public pure returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(
                    claim.stateRoot,
                    claim.claimer,
                    claim.timestamp,
                    claim.blocknumber,
                    claim.honest,
                    claim.challenger
                )
            );
    }

    function passedTest(Claim calldata claim) external view returns (bool) {
        uint256 expectedBlocks = uint256(claim.blocknumber) + (block.timestamp - uint256(claim.timestamp)) / slotTime;
        uint256 actualBlocks = block.number;
        return (expectedBlocks <= actualBlocks + maxMissingBlocks);
    }
}
