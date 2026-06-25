// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PrecompileConsumer} from "./utils/PrecompileConsumer.sol";

interface IRitualWallet {
    function deposit(uint256 lockDuration) external payable;

    function depositFor(address user, uint256 lockDuration) external payable;

    function withdraw(uint256 amount) external;

    function balanceOf(address) external view returns (uint256);

    function lockUntil(address) external view returns (uint256);
}

contract AIJudge is PrecompileConsumer {
    uint256 public constant MAX_SUBMISSIONS = 10;
    uint256 public constant MAX_ANSWER_LENGTH = 2_000;

    uint256 public nextBountyId = 1;

    IRitualWallet wallet =
        IRitualWallet(0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948);

    struct Commitment {
        address submitter;
        bytes32 hash;
    }

    struct RevealedAnswer {
        address submitter;
        string answer;
    }

    struct Bounty {
        address owner;
        string title;
        string rubric;
        uint256 reward;
        uint256 deadline;
        bool judged;
        bool finalized;
        bytes aiReview;
        uint256 winnerIndex;
        Commitment[] commitments;
        RevealedAnswer[] revealedAnswers;
        mapping(address => bool) hasCommitted;
        mapping(address => bool) hasRevealed;
    }

    struct ConvoHistory {
        string storageType;
        string path;
        string secretsName;
    }

    mapping(uint256 => Bounty) public bounties;

    event BountyCreated(
        uint256 indexed bountyId,
        address indexed owner,
        string title,
        uint256 reward,
        uint256 deadline
    );

    event CommitmentSubmitted(
        uint256 indexed bountyId,
        address indexed submitter,
        bytes32 commitment
    );

    event AnswerRevealed(
        uint256 indexed bountyId,
        address indexed submitter,
        uint256 indexed revealIndex
    );

    event AllAnswersJudged(uint256 indexed bountyId, bytes aiReview);

    event WinnerFinalized(
        uint256 indexed bountyId,
        uint256 indexed winnerIndex,
        address indexed winner,
        uint256 reward
    );

    modifier onlyOwner(uint256 bountyId) {
        require(msg.sender == bounties[bountyId].owner, "not bounty owner");
        _;
    }

    modifier bountyExists(uint256 bountyId) {
        require(bounties[bountyId].owner != address(0), "bounty not found");
        _;
    }

    function createBounty(
        string calldata title,
        string calldata rubric,
        uint256 deadline
    ) external payable returns (uint256 bountyId) {
        require(msg.value > 0, "reward required");

        bountyId = nextBountyId++;

        Bounty storage bounty = bounties[bountyId];

        bounty.owner = msg.sender;
        bounty.title = title;
        bounty.rubric = rubric;
        bounty.reward = msg.value;
        bounty.deadline = deadline;
        bounty.winnerIndex = type(uint256).max;

        emit BountyCreated(bountyId, msg.sender, title, msg.value, deadline);
    }

    /// @notice Submit a commitment hash during the submission phase (before deadline)
    /// @param bountyId The ID of the bounty
    /// @param commitment The keccak256 hash of (answer, salt, msg.sender, bountyId)
    function submitCommitment(
        uint256 bountyId,
        bytes32 commitment
    ) external bountyExists(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(block.timestamp < bounty.deadline, "commitment phase closed");
        require(!bounty.judged, "already judged");
        require(!bounty.finalized, "already finalized");
        require(
            bounty.commitments.length < MAX_SUBMISSIONS,
            "too many submissions"
        );
        require(!bounty.hasCommitted[msg.sender], "already committed");

        bounty.commitments.push(
            Commitment({submitter: msg.sender, hash: commitment})
        );
        bounty.hasCommitted[msg.sender] = true;

        emit CommitmentSubmitted(bountyId, msg.sender, commitment);
    }

    /// @notice Reveal the answer after the deadline
    /// @param bountyId The ID of the bounty
    /// @param answer The plaintext answer
    /// @param salt A random salt used during commitment
    /// The contract verifies: keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId)) == stored commitment
    function revealAnswer(
        uint256 bountyId,
        string calldata answer,
        bytes32 salt
    ) external bountyExists(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(block.timestamp >= bounty.deadline, "reveal phase not started");
        require(!bounty.judged, "already judged");
        require(!bounty.finalized, "already finalized");
        require(bounty.hasCommitted[msg.sender], "no commitment found");
        require(!bounty.hasRevealed[msg.sender], "already revealed");
        require(
            bytes(answer).length <= MAX_ANSWER_LENGTH,
            "answer too long"
        );

        // Compute the hash to verify against the commitment
        bytes32 computedHash = keccak256(
            abi.encodePacked(answer, salt, msg.sender, bountyId)
        );

        // Find the commitment and verify
        bool found = false;
        for (uint256 i = 0; i < bounty.commitments.length; i++) {
            if (bounty.commitments[i].submitter == msg.sender) {
                require(
                    bounty.commitments[i].hash == computedHash,
                    "hash mismatch"
                );
                found = true;
                break;
            }
        }

        require(found, "commitment not found");

        bounty.revealedAnswers.push(
            RevealedAnswer({submitter: msg.sender, answer: answer})
        );
        bounty.hasRevealed[msg.sender] = true;

        emit AnswerRevealed(
            bountyId,
            msg.sender,
            bounty.revealedAnswers.length - 1
        );
    }

    /// @notice Judge all revealed answers using the LLM precompile
    /// @param bountyId The ID of the bounty
    /// @param llmInput The input data for the LLM inference
    function judgeAll(
        uint256 bountyId,
        bytes calldata llmInput
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(block.timestamp >= bounty.deadline, "judging before deadline");
        require(!bounty.judged, "already judged");
        require(!bounty.finalized, "already finalized");
        require(bounty.revealedAnswers.length > 0, "no revealed answers");

        bytes memory output = _executePrecompile(
            LLM_INFERENCE_PRECOMPILE,
            llmInput
        );

        (
            bool hasError,
            bytes memory completionData,
            ,
            string memory errorMessage,

        ) = abi.decode(output, (bool, bytes, bytes, string, ConvoHistory));

        require(!hasError, errorMessage);

        bounty.judged = true;
        bounty.aiReview = completionData;

        emit AllAnswersJudged(bountyId, completionData);
    }

    /// @notice Finalize the winner and distribute the reward
    /// @param bountyId The ID of the bounty
    /// @param winnerIndex The index of the winner in the revealedAnswers array
    function finalizeWinner(
        uint256 bountyId,
        uint256 winnerIndex
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(bounty.judged, "not judged yet");
        require(!bounty.finalized, "already finalized");
        require(
            winnerIndex < bounty.revealedAnswers.length,
            "invalid winner index"
        );

        bounty.finalized = true;
        bounty.winnerIndex = winnerIndex;

        address winner = bounty.revealedAnswers[winnerIndex].submitter;
        uint256 reward = bounty.reward;
        bounty.reward = 0;

        (bool ok, ) = payable(winner).call{value: reward}("");
        require(ok, "payment failed");

        emit WinnerFinalized(bountyId, winnerIndex, winner, reward);
    }

    function getBounty(
        uint256 bountyId
    )
        external
        view
        bountyExists(bountyId)
        returns (
            address owner,
            string memory title,
            string memory rubric,
            uint256 reward,
            uint256 deadline,
            bool judged,
            bool finalized,
            uint256 commitmentCount,
            uint256 revealedCount,
            uint256 winnerIndex,
            bytes memory aiReview
        )
    {
        Bounty storage bounty = bounties[bountyId];

        return (
            bounty.owner,
            bounty.title,
            bounty.rubric,
            bounty.reward,
            bounty.deadline,
            bounty.judged,
            bounty.finalized,
            bounty.commitments.length,
            bounty.revealedAnswers.length,
            bounty.winnerIndex,
            bounty.aiReview
        );
    }

    /// @notice Get a revealed answer by index
    /// @param bountyId The ID of the bounty
    /// @param index The index in the revealedAnswers array
    function getRevealedAnswer(
        uint256 bountyId,
        uint256 index
    )
        external
        view
        bountyExists(bountyId)
        returns (address submitter, string memory answer)
    {
        Bounty storage bounty = bounties[bountyId];

        require(index < bounty.revealedAnswers.length, "invalid index");

        RevealedAnswer storage revealedAnswer = bounty.revealedAnswers[index];

        return (revealedAnswer.submitter, revealedAnswer.answer);
    }

    /// @notice Get the number of commitments for a bounty
    function getCommitmentCount(
        uint256 bountyId
    ) external view bountyExists(bountyId) returns (uint256) {
        return bounties[bountyId].commitments.length;
    }

    /// @notice Get the number of revealed answers for a bounty
    function getRevealedCount(
        uint256 bountyId
    ) external view bountyExists(bountyId) returns (uint256) {
        return bounties[bountyId].revealedAnswers.length;
    }
}
