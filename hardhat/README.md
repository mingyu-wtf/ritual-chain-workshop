# Privacy-Preserving AI Bounty Judge - Commit-Reveal Implementation

A smart contract implementing a **commit-reveal scheme** to ensure users cannot see or copy each other's answers during the bounty submission phase.

## Overview

This implementation uses a two-phase submission model:
1. **Commitment Phase** (before deadline): Users submit only a hashed commitment
2. **Reveal Phase** (after deadline): Users reveal their answers and the contract verifies them
3. **Judging Phase**: Only verified revealed answers are judged by the AI
4. **Finalization Phase**: Bounty owner selects and rewards the winner

## Lifecycle

### Phase 1: Commitment (Before Deadline)
- User creates a commitment hash: `keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId))`
- User calls `submitCommitment(bountyId, hash)` to store only the hash on-chain
- **The answer is completely hidden** - no one can see what the user submitted

### Phase 2: Reveal (After Deadline)
- User calls `revealAnswer(bountyId, answer, salt)` with the plaintext answer
- Contract verifies the revealed answer by recomputing the hash and comparing it to the stored commitment
- If hash matches, the answer is added to the revealed answers list
- If hash doesn't match, the transaction reverts with "hash mismatch"

### Phase 3: Judging (After All Reveals)
- Bounty owner calls `judgeAll(bountyId, llmInput)` 
- Only **revealed and verified answers** are passed to the AI for evaluation
- The AI returns judgment data

### Phase 4: Finalization
- Bounty owner calls `finalizeWinner(bountyId, winnerIndex)`
- The winner is selected from the revealed answers
- Reward is transferred to the winner

## What Is Public vs Private

| Data | Status | Location | Details |
|------|--------|----------|---------|
| Bounty details (title, rubric, deadline, reward) | ✅ Public | On-chain | Anyone can view |
| User commitments (hashes) | ✅ Public | On-chain | Hashes visible, answers hidden |
| User addresses (who committed) | ✅ Public | On-chain | Can see who participated |
| Plaintext answers (before reveal) | 🔒 Private | Off-chain only | Never submitted during commitment phase |
| Plaintext answers (after reveal) | ✅ Public | On-chain | Only after deadline passes |
| AI review results | ✅ Public | On-chain | Stored after judging |
| Winner info | ✅ Public | On-chain | Revealed after finalization |

## On-Chain vs Off-Chain Storage

| Component | Storage | Why |
|-----------|---------|-----|
| Commitment hash | On-chain | Needed to verify later; must be tamper-proof |
| Plaintext answers | Off-chain (user keeps) | Reduces data; user must store locally with salt |
| Salt | Off-chain (user keeps) | Secret; never submitted until reveal phase |
| AI review bytes | On-chain | Owner decision; recorded for transparency |
| Bounty metadata | On-chain | Required for bounty lookup and administration |

## Contract Functions

### Core Functions

```solidity
// Commitment phase (before deadline)
submitCommitment(uint256 bountyId, bytes32 commitment)

// Reveal phase (after deadline)
revealAnswer(uint256 bountyId, string calldata answer, bytes32 salt)

// Judging phase
judgeAll(uint256 bountyId, bytes calldata llmInput)

// Finalization phase
finalizeWinner(uint256 bountyId, uint256 winnerIndex)
```

### View Functions

```solidity
getBounty(uint256 bountyId) returns bounty details
getRevealedAnswer(uint256 bountyId, uint256 index) returns revealed answer
getCommitmentCount(uint256 bountyId) returns number of commitments
getRevealedCount(uint256 bountyId) returns number of revealed answers
```

## Events Emitted

- **CommitmentSubmitted**: User submitted a commitment hash
- **AnswerRevealed**: User revealed a verified answer
- **AllAnswersJudged**: AI judging completed
- **WinnerFinalized**: Winner selected and reward distributed

## Require Checks Implemented

✅ Bounty exists before any operation  
✅ Commitment only accepted before deadline  
✅ Reveal only allowed after deadline  
✅ No duplicate commitments from the same address  
✅ Reveal hash must exactly match stored commitment  
✅ Only bounty owner can judge  
✅ Only bounty owner can finalize  
✅ Winner index must be valid (within revealed answers range)  
✅ No operations allowed after judging  
✅ No operations allowed after finalization  

## Test Plan

### Unit Tests (Recommended)

1. **Commitment Phase**
   - Submit valid commitment hash
   - Reject commitments after deadline
   - Reject duplicate commitments from same user
   - Verify commitment is stored correctly

2. **Reveal Phase**
   - Reject reveals before deadline
   - Accept valid reveals with correct hash
   - Reject reveals with mismatched hash (wrong answer, wrong salt)
   - Verify revealed answer is stored
   - Prevent double reveals from same user

3. **Judging Phase**
   - Verify judging only works on revealed answers
   - Verify judging can only be called by owner
   - Verify AI review data is stored correctly

4. **Finalization Phase**
   - Verify winner must be selected from revealed answers
   - Verify only owner can finalize
   - Verify reward is transferred correctly
   - Verify state changes after finalization

5. **Edge Cases**
   - Zero commitments/reveals before judging
   - Maximum submissions (MAX_SUBMISSIONS = 10)
   - Large answer strings (up to MAX_ANSWER_LENGTH = 2000 bytes)

## Compilation & Deployment

### Compile

```shell
cd hardhat
npx hardhat compile
```

### Deploy to Local Chain

```shell
npx hardhat ignition deploy ignition/modules/AIJudge.ts
```

### Deploy to Sepolia

Requires `SEPOLIA_PRIVATE_KEY` environment variable or hardhat-keystore configuration:

```shell
npx hardhat ignition deploy ignition/modules/AIJudge.ts --network sepolia
```

## Architecture Notes

- **Two-Phase Hiding**: The commit-reveal scheme prevents front-running and copying during submission
- **Verifiable Computation**: All answers are cryptographically verified against stored commitments
- **Owner Control**: Only bounty owner can judge and finalize (AI is advisory, not authoritative)
- **Scalability**: Supports up to 10 submissions per bounty; limited by on-chain storage
- **Gas Efficiency**: Commitments are 32-byte hashes (very small); large answers only stored after reveal

## Reflection

The commit-reveal scheme elegantly solves the privacy problem in decentralized bounty systems by separating the submission into two temporal phases. During the commitment phase, users' answers remain completely hidden—only cryptographic hashes are visible on-chain—preventing others from copying or being influenced by earlier submissions. The reveal phase, activated only after the deadline, ensures fairness by allowing all users equal time to keep their answers secret. The owner's exclusive ability to judge and finalize preserves human oversight, acknowledging that AI can make errors and should not have unilateral authority over reward distribution. This design balances transparency (verifiable results), privacy (hidden answers), and trust (owner-controlled finalization), making it suitable for fair bounty systems on public blockchains where participants are initially untrusted.
```

After setting the variable, you can run the deployment with the Sepolia network:

```shell
npx hardhat ignition deploy --network sepolia ignition/modules/Counter.ts
```
