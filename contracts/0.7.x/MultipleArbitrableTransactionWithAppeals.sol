/**
 *  @authors: [@unknownunknown1, @fnanni-0]
 *  @reviewers: [@ferittuncer, @epiqueras, @nix1g]
 *  @auditors: []
 *  @bounties: []
 */

pragma solidity >=0.7.1;
pragma experimental ABIEncoderV2;

import "@kleros/erc-792/contracts/IArbitrable.sol";
import "@kleros/erc-792/contracts/IArbitrator.sol";
import "@kleros/erc-792/contracts/erc-1497/IEvidence.sol";
import "@kleros/ethereum-libraries/contracts/CappedMath.sol";

contract MultipleArbitrableTransactionWithAppeals is IArbitrable, IEvidence {
    
    using CappedMath for uint256;

    // **************************** //
    // *    Contract variables    * //
    // **************************** //

    uint256 public constant AMOUNT_OF_CHOICES = 2;
    uint256 public constant MULTIPLIER_DIVISOR = 10000; // Divisor parameter for multipliers.

    enum Party {None, Sender, Receiver}
    enum Status {NoDispute, WaitingSender, WaitingReceiver, DisputeCreated, Resolved}
    enum Resolution {TransactionExecuted, TimeoutBySender, TimeoutByReceiver, RulingEnforced}

    struct Transaction {
        // Packed together {
        address payable sender;
        uint32 deadline; // Timestamp at which the transaction can be automatically executed if not disputed.
        uint32 lastInteraction; // Last interaction for the dispute procedure.
        // }
        // Packed together {
        address payable receiver;
        Status status;
        Party ruling; // The ruling given by the arbitrator.
        uint64 roundCounter;
        // }
        uint256 amount;
        uint256 disputeID; // If dispute exists, the ID of the dispute.
        uint256 senderFee; // Total fees paid by the sender.
        uint256 receiverFee; // Total fees paid by the receiver.
        mapping(uint256 => Round) rounds;
    }
    
    struct Round {
        uint256[3] paidFees; // Tracks the fees paid by each side in this round.
        Party sideFunded; // If the round is appealed, i.e. this is not the last round, Party.None means that both sides have paid.
        uint256 feeRewards; // Sum of reimbursable fees and stake rewards available to the parties that made contributions to the side that ultimately wins a dispute.
        mapping(address => uint256[3]) contributions; // Maps contributors to their contributions for each side.
    }

    IArbitrator public immutable arbitrator; // Address of the arbitrator contract. TRUSTED.
    bytes public arbitratorExtraData; // Extra data to set up the arbitration.
    uint256 public immutable feeTimeout; // Time in seconds a party can take to pay arbitration fees before being considered unresponsive and lose the dispute.
    
    uint256 public immutable sharedStakeMultiplier; // Multiplier for calculating the appeal fee that must be paid by the submitter in the case where there is no winner or loser (e.g. when the arbitrator ruled "refuse to arbitrate").
    uint256 public immutable winnerStakeMultiplier; // Multiplier for calculating the appeal fee of the party that won the previous round.
    uint256 public immutable loserStakeMultiplier; // Multiplier for calculating the appeal fee of the party that lost the previous round.

    Transaction[] public transactions;
    mapping (uint256 => uint256) public disputeIDtoTransactionID; // One-to-one relationship between the dispute and the transaction.

    // **************************** //
    // *          Events          * //
    // **************************** //

    /** @dev To be emitted when a party pays or reimburses the other.
     *  @param _transactionID The index of the transaction.
     *  @param _amount The amount paid.
     *  @param _party The party that paid.
     */
    event Payment(uint256 indexed _transactionID, uint256 _amount, address _party);

    /** @dev Indicate that a party has to pay a fee or would otherwise be considered as losing.
     *  @param _transactionID The index of the transaction.
     *  @param _party The party who has to pay.
     */
    event HasToPayFee(uint256 indexed _transactionID, Party _party);

    /** @dev Emitted when a transaction is created.
     *  @param _transactionID The index of the transaction.
     *  @param _sender The address of the sender.
     *  @param _receiver The address of the receiver.
     *  @param _amount The initial amount in the transaction.
     */
    event TransactionCreated(uint256 indexed _transactionID, address indexed _sender, address indexed _receiver, uint256 _amount);

    /** @dev To be emitted when a transaction is resolved, either by its execution, a timeout or because a ruling was enforced.
     *  @param _transactionID The ID of the respective transaction.
     *  @param _resolution Short description of what caused the transaction to be solved.
     */
    event TransactionResolved(uint256 indexed _transactionID, Resolution indexed _resolution);

    /** @dev To be emitted when the appeal fees of one of the parties are fully funded.
     *  @param _transactionID The ID of the respective transaction.
     *  @param _party The party that is fully funded.
     */
    event HasPaidAppealFee(uint256 indexed _transactionID, Party _party);

    /**
     * @dev To be emitted when someone contributes to the appeal process.
     * @param _transactionID The ID of the respective transaction.
     * @param _party The party which received the contribution.
     * @param _contributor The address of the contributor.
     * @param _amount The amount contributed.
     */
    event AppealContribution(uint256 indexed _transactionID, Party _party, address _contributor, uint256 _amount);

    // **************************** //
    // *    Arbitrable functions  * //
    // *    Modifying the state   * //
    // **************************** //

    /** @dev Constructor.
     *  @param _arbitrator The arbitrator of the contract.
     *  @param _arbitratorExtraData Extra data for the arbitrator.
     *  @param _feeTimeout Arbitration fee timeout for the parties.
     *  @param _sharedStakeMultiplier Multiplier of the appeal cost that the submitter must pay for a round when there is no winner/loser in the previous round. In basis points.
     *  @param _winnerStakeMultiplier Multiplier of the appeal cost that the winner has to pay for a round. In basis points.
     *  @param _loserStakeMultiplier Multiplier of the appeal cost that the loser has to pay for a round. In basis points.
     */
    constructor (
        IArbitrator _arbitrator,
        bytes memory _arbitratorExtraData,
        uint256 _feeTimeout,
        uint256 _sharedStakeMultiplier,
        uint256 _winnerStakeMultiplier,
        uint256 _loserStakeMultiplier
    ) {
        arbitrator = _arbitrator;
        arbitratorExtraData = _arbitratorExtraData;
        feeTimeout = _feeTimeout;
        sharedStakeMultiplier = _sharedStakeMultiplier;
        winnerStakeMultiplier = _winnerStakeMultiplier;
        loserStakeMultiplier = _loserStakeMultiplier;
    }

    /** @dev Create a transaction.
     *  @param _timeoutPayment Time after which a party can automatically execute the arbitrable transaction.
     *  @param _receiver The recipient of the transaction.
     *  @param _metaEvidence Link to the meta-evidence.
     *  @return transactionID The index of the transaction.
     */
    function createTransaction(
        uint32 _timeoutPayment,
        address payable _receiver,
        string calldata _metaEvidence
    ) external payable returns (uint256 transactionID) {
        
        uint256 transactionID = transactions.length;
        Transaction storage transaction = transactions.push();
        transaction.sender = msg.sender;
        transaction.receiver = _receiver;
        transaction.amount = msg.value;
        transaction.deadline = uint32(block.timestamp + _timeoutPayment);
        transaction.lastInteraction = uint32(block.timestamp);

        emit MetaEvidence(transactionID, _metaEvidence);
        emit TransactionCreated(transactionID, msg.sender, _receiver, msg.value);
        return transactionID;
    }

    /** @dev Pay receiver. To be called if the good or service is provided.
     *  @param _transactionID The index of the transaction.
     *  @param _amount Amount to pay in wei.
     */
    function pay(uint256 _transactionID, uint256 _amount) external {
        Transaction storage transaction = transactions[_transactionID];
        require(transaction.sender == msg.sender, "The caller must be the sender.");
        require(transaction.status == Status.NoDispute, "The transaction must not be disputed.");

        uint256 amount = transaction.amount;
        require(_amount <= amount, "Maximum amount available for payment exceeded.");

        transaction.receiver.send(_amount); // It is the user responsibility to accept ETH.
        transaction.amount = amount - _amount;

        emit Payment(_transactionID, _amount, msg.sender);
    }

    /** @dev Reimburse sender. To be called if the good or service can't be fully provided.
     *  @param _transactionID The index of the transaction.
     *  @param _amountReimbursed Amount to reimburse in wei.
     */
    function reimburse(uint256 _transactionID, uint256 _amountReimbursed) external {
        Transaction storage transaction = transactions[_transactionID];
        require(transaction.receiver == msg.sender, "The caller must be the receiver.");
        require(transaction.status == Status.NoDispute, "The transaction must not be disputed.");

        uint256 amount = transaction.amount;
        require(_amountReimbursed <= amount, "Maximum reimbursement available exceeded.");

        transaction.sender.send(_amountReimbursed); // It is the user responsibility to accept ETH.
        transaction.amount = amount - _amountReimbursed;

        emit Payment(_transactionID, _amountReimbursed, msg.sender);
    }

    /** @dev Transfer the transaction's amount to the receiver if the timeout has passed.
     *  @param _transactionID The index of the transaction.
     */
    function executeTransaction(uint256 _transactionID) external {
        Transaction storage transaction = transactions[_transactionID];
        require(block.timestamp >= transaction.deadline, "Deadline not passed.");
        require(transaction.status == Status.NoDispute, "The transaction must not be disputed.");

        transaction.receiver.send(transaction.amount); // It is the user responsibility to accept ETH.
        transaction.amount = 0;

        transaction.status = Status.Resolved;

        emit TransactionResolved(_transactionID, Resolution.TransactionExecuted);
    }

    /** @dev Pay the arbitration fee to raise a dispute. To be called by the sender. UNTRUSTED.
     *  Note that the arbitrator can have createDispute throw, which will make this function throw and therefore lead to a party being timed-out.
     *  This is not a vulnerability as the arbitrator can rule in favor of one party anyway.
     *  @param _transactionID The index of the transaction.
     */
    function payArbitrationFeeBySender(uint256 _transactionID) external payable {
        Transaction storage transaction = transactions[_transactionID];
        require(transaction.status < Status.DisputeCreated, "Dispute has already been created or because the transaction has been executed.");
        require(msg.sender == transaction.sender, "The caller must be the sender.");

        uint256 arbitrationCost = arbitrator.arbitrationCost(arbitratorExtraData);
        uint256 senderFee = transaction.senderFee;
        senderFee += msg.value;
        // Require that the total pay at least the arbitration cost.
        require(senderFee >= arbitrationCost, "The sender fee must cover arbitration costs.");
        transaction.senderFee = senderFee;

        transaction.lastInteraction = uint32(block.timestamp);

        // The receiver still has to pay. This can also happen if he has paid, but arbitrationCost has increased.
        if (transaction.receiverFee < arbitrationCost) {
            transaction.status = Status.WaitingReceiver;
            emit HasToPayFee(_transactionID, Party.Receiver);
        } else { // The receiver has also paid the fee. We create the dispute.
            raiseDispute(_transactionID, transaction, arbitrationCost);
        }
    }

    /** @dev Pay the arbitration fee to raise a dispute. To be called by the receiver. UNTRUSTED.
     *  Note that this function mirrors payArbitrationFeeBySender.
     *  @param _transactionID The index of the transaction.
     */
    function payArbitrationFeeByReceiver(uint256 _transactionID) external payable {
        Transaction storage transaction = transactions[_transactionID];
        require(transaction.status < Status.DisputeCreated, "Dispute has already been created or because the transaction has been executed.");
        require(msg.sender == transaction.receiver, "The caller must be the receiver.");
        
        uint256 arbitrationCost = arbitrator.arbitrationCost(arbitratorExtraData);
        uint256 receiverFee = transaction.receiverFee;
        receiverFee += msg.value;
        // Require that the total paid to be at least the arbitration cost.
        require(receiverFee >= arbitrationCost, "The receiver fee must cover arbitration costs.");
        transaction.receiverFee = receiverFee;

        transaction.lastInteraction = uint32(block.timestamp);
        // The sender still has to pay. This can also happen if he has paid, but arbitrationCost has increased.
        if (transaction.senderFee < arbitrationCost) {
            transaction.status = Status.WaitingSender;
            emit HasToPayFee(_transactionID, Party.Sender);
        } else { // The sender has also paid the fee. We create the dispute.
            raiseDispute(_transactionID, transaction, arbitrationCost);
        }
    }

    /** @dev Reimburse sender if receiver fails to pay the fee.
     *  @param _transactionID The index of the transaction.
     */
    function timeOutBySender(uint256 _transactionID) external {
        Transaction storage transaction = transactions[_transactionID];
        require(transaction.status == Status.WaitingReceiver, "The transaction is not waiting on the receiver.");
        require(block.timestamp - transaction.lastInteraction >= feeTimeout, "Timeout time has not passed yet.");

        if (transaction.receiverFee != 0) {
            transaction.receiver.send(transaction.receiverFee); // It is the user responsibility to accept ETH.
            transaction.receiverFee = 0;
        }

        transaction.sender.send(transaction.senderFee + transaction.amount); // It is the user responsibility to accept ETH.
        transaction.amount = 0;
        transaction.senderFee = 0;
        transaction.status = Status.Resolved;

        emit TransactionResolved(_transactionID, Resolution.TimeoutBySender);
    }

    /** @dev Pay receiver if sender fails to pay the fee.
     *  @param _transactionID The index of the transaction.
     */
    function timeOutByReceiver(uint256 _transactionID) external {
        Transaction storage transaction = transactions[_transactionID];
        require(transaction.status == Status.WaitingSender, "The transaction is not waiting on the sender.");
        require(block.timestamp - transaction.lastInteraction >= feeTimeout, "Timeout time has not passed yet.");

        if (transaction.senderFee != 0) {
            transaction.sender.send(transaction.senderFee); // It is the user responsibility to accept ETH.
            transaction.senderFee = 0;
        }

        transaction.receiver.send(transaction.receiverFee + transaction.amount); // It is the user responsibility to accept ETH.
        transaction.amount = 0;
        transaction.receiverFee = 0;
        transaction.status = Status.Resolved;

        emit TransactionResolved(_transactionID, Resolution.TimeoutByReceiver);
    }

    /** @dev Create a dispute. UNTRUSTED.
     *  @param _transactionID The index of the transaction.
     *  @param _transaction The transaction state.
     *  @param _arbitrationCost Amount to pay the arbitrator.
     */
    function raiseDispute(uint256 _transactionID, Transaction storage _transaction, uint256 _arbitrationCost) internal {
        _transaction.status = Status.DisputeCreated;
        _transaction.roundCounter = 1;
        uint256 disputeID = arbitrator.createDispute{value: _arbitrationCost}(AMOUNT_OF_CHOICES, arbitratorExtraData);
        _transaction.disputeID;
        disputeIDtoTransactionID[disputeID] = _transactionID;
        emit Dispute(arbitrator, disputeID, _transactionID, _transactionID);

        // Refund sender if it overpaid.
        uint256 senderFee = _transaction.senderFee;
        if (senderFee > _arbitrationCost) {
            uint256 extraFeeSender = senderFee - _arbitrationCost;
            _transaction.senderFee = _arbitrationCost;
            _transaction.sender.send(extraFeeSender); // It is the user responsibility to accept ETH.
        }

        // Refund receiver if it overpaid.
        uint256 receiverFee = _transaction.receiverFee;
        if (receiverFee > _arbitrationCost) {
            uint256 extraFeeReceiver = receiverFee - _arbitrationCost;
            _transaction.receiverFee = _arbitrationCost;
            _transaction.receiver.send(extraFeeReceiver); // It is the user responsibility to accept ETH.
        }
    }

    /** @dev Submit a reference to evidence. EVENT.
     *  @param _transactionID The index of the transaction.
     *  @param _evidence A link to an evidence using its URI.
     */
    function submitEvidence(uint256 _transactionID, string calldata _evidence) external {
        Transaction storage transaction = transactions[_transactionID];
        require(
            msg.sender == transaction.sender || msg.sender == transaction.receiver,
            "The caller must be the sender or the receiver."
        );
        require(
            transaction.status < Status.Resolved,
            "Must not send evidence if the dispute is resolved."
        );

        emit Evidence(arbitrator, _transactionID, msg.sender, _evidence);
    }

    /** @dev Takes up to the total amount required to fund a side of an appeal. Reimburses the rest. Creates an appeal if both sides are fully funded.
     *  @param _transactionID The ID of the disputed transaction.
     *  @param _side The party that pays the appeal fee.
     */
    function fundAppeal(uint256 _transactionID, Party _side) external payable {
        Transaction storage transaction = transactions[_transactionID];
        require(_side != Party.None, "Wrong party.");
        require(transaction.status == Status.DisputeCreated, "No dispute to appeal");

        uint256 currentRound = uint256(transaction.roundCounter - 1);
        Round storage round = transaction.rounds[currentRound];
        require(_side != round.sideFunded, "Appeal fee has already been paid.");

        (uint256 appealCost, uint256 totalCost) = getAppealFeeComponents(transaction, _transactionID, uint256(_side));
        uint256 paidFee = round.paidFees[uint256(_side)]; // Use local variable for gas saving purposes.
        // Take up to the amount necessary to fund the current round at the current costs.
        (uint256 contribution, uint256 remainingETH) = calculateContribution(msg.value, totalCost.subCap(paidFee));
        round.contributions[msg.sender][uint256(_side)] += contribution;
        paidFee += contribution;
        round.paidFees[uint256(_side)] = paidFee;

        emit AppealContribution(_transactionID, _side, msg.sender, contribution);

        // Reimburse leftover ETH if any.
        if (remainingETH > 0)
            msg.sender.send(remainingETH); // It is the user responsibility to accept ETH.
        
        if (paidFee >= totalCost) {
            if (round.sideFunded == Party.None) {
                round.sideFunded = _side;
            } else {
                // Both sides are fully funded. Create an appeal.
                arbitrator.appeal{value: appealCost}(transaction.disputeID, arbitratorExtraData);
                round.feeRewards = (paidFee + round.paidFees[3-uint256(_side)]).subCap(appealCost);
                transaction.roundCounter = uint64(currentRound + 2);
                round.sideFunded = Party.None;
            }
            emit HasPaidAppealFee(_transactionID, _side);
        }
    } 

    function getAppealFeeComponents(
        Transaction storage _transaction,
        uint256 _transactionID,
        uint256 _side
    ) internal view returns (uint256 appealCost, uint256 totalCost) {
        IArbitrator _arbitrator = arbitrator;
        uint256 disputeID = _transaction.disputeID;

        (uint256 appealPeriodStart, uint256 appealPeriodEnd) = _arbitrator.appealPeriod(disputeID);
        require(block.timestamp >= appealPeriodStart && block.timestamp < appealPeriodEnd, "Not in appeal period.");

        uint256 multiplier;
        uint256 winner = _arbitrator.currentRuling(disputeID);
        if (winner == _side){
            multiplier = winnerStakeMultiplier;
        } else if (winner == 0){
            multiplier = sharedStakeMultiplier;
        } else {
            require(block.timestamp < (appealPeriodEnd + appealPeriodStart)/2, "Not in loser's appeal period.");
            multiplier = loserStakeMultiplier;
        }

        appealCost = _arbitrator.appealCost(disputeID, arbitratorExtraData);
        totalCost = appealCost.addCap(appealCost.mulCap(multiplier) / MULTIPLIER_DIVISOR);
    }
    
    /** @dev Returns the contribution value and remainder from available ETH and required amount.
     *  @param _available The amount of ETH available for the contribution.
     *  @param _requiredAmount The amount of ETH required for the contribution.
     *  @return taken The amount of ETH taken.
     *  @return remainder The amount of ETH left from the contribution.
     */
    function calculateContribution(uint256 _available, uint256 _requiredAmount)
        internal
        pure
        returns(uint256 taken, uint256 remainder)
    {
        if (_requiredAmount > _available)
            return (_available, 0); // Take whatever is available, return 0 as leftover ETH.

        remainder = _available - _requiredAmount;
        return (_requiredAmount, remainder);
    }
    
    /** @dev Updates the state of contributions of appeal rounds which are going to be withdrawn.
     *  Caller functions MUST: (1) check that the transaction is valid and Resolved and (2) send the rewards to the _beneficiary.
     *  @param _beneficiary The address that made contributions.
     *  @param _transactionID The ID of the associated transaction.
     *  @param _round The round from which to withdraw.
     *  @param _finalRuling The final ruling of this transaction.
     *  @return reward The amount of wei available to withdraw from _round.
     */
    function _withdrawFeesAndRewards(address _beneficiary, uint256 _transactionID, uint256 _round, uint256 _finalRuling) internal returns(uint256 reward) {
        Transaction storage transaction = transactions[_transactionID];
        Round storage round = transaction.rounds[_round];
        uint256[3] storage contributionTo = round.contributions[_beneficiary];
        uint256 lastRound = transaction.roundCounter - 1;

        if (_round == lastRound) {
            // Allow to reimburse if funding was unsuccessful.
            reward = contributionTo[uint256(Party.Sender)] + contributionTo[uint256(Party.Receiver)];
        } else if (_finalRuling == uint256(Party.None)) {
            // Reimburse unspent fees proportionally if there is no winner and loser.
            uint256 totalFeesPaid = round.paidFees[uint256(Party.Sender)] + round.paidFees[uint256(Party.Receiver)];
            uint256 totalBeneficiaryContributions = contributionTo[uint256(Party.Sender)] + contributionTo[uint256(Party.Receiver)];
            reward = totalFeesPaid > 0 ? (totalBeneficiaryContributions * round.feeRewards) / totalFeesPaid : 0;
        } else {
            // Reward the winner.
            uint256 paidFees = round.paidFees[_finalRuling];
            reward = paidFees > 0
                ? (contributionTo[_finalRuling] * round.feeRewards) / paidFees
                : 0;
        }
        contributionTo[uint256(Party.Sender)] = 0;
        contributionTo[uint256(Party.Receiver)] = 0;
    }
    
    /** @dev Witdraws contributions of appeal rounds. Reimburses contributions if the appeal was not fully funded. 
     *  If the appeal was fully funded, sends the fee stake rewards and reimbursements proportional to the contributions made to the winner of a dispute.
     *  @param _beneficiary The address that made contributions.
     *  @param _transactionID The ID of the associated transaction.
     *  @param _round The round from which to withdraw.
     */
    function withdrawFeesAndRewards(address payable _beneficiary, uint256 _transactionID, uint256 _round) external {
        Transaction storage transaction = transactions[_transactionID];
        require(transaction.status == Status.Resolved, "The transaction must be resolved.");

        uint256 reward = _withdrawFeesAndRewards(_beneficiary, _transactionID, _round, uint256(transaction.ruling));
        _beneficiary.send(reward); // It is the user responsibility to accept ETH.
    }
    
    /** @dev Withdraws contributions of multiple appeal rounds at once. This function is O(n) where n is the number of rounds. 
     *  This could exceed the gas limit, therefore this function should be used only as a utility and not be relied upon by other contracts.
     *  @param _beneficiary The address that made contributions.
     *  @param _transactionID The ID of the associated transaction.
     *  @param _cursor The round from where to start withdrawing.
     *  @param _count The number of rounds to iterate. If set to 0 or a value larger than the number of rounds, iterates until the last round.
     */
    function batchRoundWithdraw(address payable _beneficiary, uint256 _transactionID, uint256 _cursor, uint256 _count) external {
        Transaction storage transaction = transactions[_transactionID];
        require(transaction.status == Status.Resolved, "The transaction must be resolved.");
        uint256 finalRuling = uint256(transaction.ruling);

        uint256 reward;
        uint256 totalRounds = transaction.roundCounter;
        for (uint256 i = _cursor; i<totalRounds && (_count==0 || i<_cursor+_count); i++)
            reward += _withdrawFeesAndRewards(_beneficiary, _transactionID, i, finalRuling);
        _beneficiary.send(reward); // It is the user responsibility to accept ETH.
    }

    /** @dev Give a ruling for a dispute. Must be called by the arbitrator to enforce the final ruling.
     *  The purpose of this function is to ensure that the address calling it has the right to rule on the contract.
     *  @param _disputeID ID of the dispute in the Arbitrator contract.
     *  @param _ruling Ruling given by the arbitrator. Note that 0 is reserved for "Not able/wanting to make a decision".
     */
    function rule(uint256 _disputeID, uint256 _ruling) public override {
        IArbitrator _arbitrator = arbitrator;

        uint256 _transactionID = disputeIDtoTransactionID[_disputeID];
        Transaction storage transaction = transactions[_transactionID];
        require(
            transaction.status == Status.DisputeCreated &&
            msg.sender == address(_arbitrator) &&
            _ruling <= AMOUNT_OF_CHOICES, 
            "Ruling can't be processed."
        );
        
        Round storage lastRound = transaction.rounds[uint256(transaction.roundCounter - 1)];

        // If only one side paid its fees we assume the ruling to be in its favor.
        Party finalRuling;
        if (lastRound.sideFunded == Party.None)
            finalRuling = Party(_ruling);
        else
            finalRuling = lastRound.sideFunded;
        transaction.ruling = finalRuling;

        emit Ruling(_arbitrator, _disputeID, uint256(finalRuling));
        executeRuling(_transactionID, transaction, finalRuling);
    }
    
    /** @dev Execute a ruling of a dispute. It reimburses the fee to the winning party.
     *  @param _transactionID The index of the transaction.
     *  @param _transaction The transaction state.
     *  @param _ruling The transaction state.
     */
    function executeRuling(uint256 _transactionID, Transaction storage _transaction, Party _ruling) internal {
        // Give the arbitration fee back.
        // Note that we use send to prevent a party from blocking the execution.
        if (_ruling == Party.Sender) {
            _transaction.sender.send(_transaction.senderFee + _transaction.amount);
        } else if (_ruling == Party.Receiver) {
            _transaction.receiver.send(_transaction.receiverFee + _transaction.amount);
        } else {
            uint256 splitAmount = (_transaction.senderFee + _transaction.amount) / 2;
            _transaction.sender.send(splitAmount);
            _transaction.receiver.send(splitAmount);
        }

        _transaction.amount = 0;
        _transaction.senderFee = 0;
        _transaction.receiverFee = 0;
        _transaction.status = Status.Resolved;

        emit TransactionResolved(_transactionID, Resolution.RulingEnforced);
    }

    // **************************** //
    // *     Constant getters     * //
    // **************************** //
    
    /** @dev Returns the sum of withdrawable wei from appeal rounds. This function is O(n), where n is the number of rounds of the transaction. 
     *  This could exceed the gas limit, therefore this function should only be used for interface display and not by other contracts.
     *  @param _transactionID The index of the transaction.
     *  @param _beneficiary The contributor for which to query.
     *  @return total The total amount of wei available to withdraw.
     */
    function amountWithdrawable(uint256 _transactionID, address _beneficiary) external view returns (uint256 total) {
        Transaction storage transaction = transactions[_transactionID];
        if (transaction.status != Status.Resolved) return total;

        uint256 finalRuling = uint256(transaction.ruling);
        uint256 totalRounds = uint256(transaction.roundCounter);
        for (uint256 i = 0; i < totalRounds; i++) {
            Round storage round = transaction.rounds[i];
            if (i == totalRounds - 1) {
                total += round.contributions[_beneficiary][uint256(Party.Sender)] + round.contributions[_beneficiary][uint256(Party.Receiver)];
            } else if (finalRuling == uint256(Party.None)) {
                uint256 totalFeesPaid = round.paidFees[uint256(Party.Sender)] + round.paidFees[uint256(Party.Receiver)];
                uint256 totalBeneficiaryContributions = round.contributions[_beneficiary][uint256(Party.Sender)] + round.contributions[_beneficiary][uint256(Party.Receiver)];
                total += totalFeesPaid > 0 ? (totalBeneficiaryContributions * round.feeRewards) / totalFeesPaid : 0;
            } else {
                total += round.paidFees[finalRuling] > 0
                    ? (round.contributions[_beneficiary][finalRuling] * round.feeRewards) / round.paidFees[finalRuling]
                    : 0;
            }
        }
    }

    /** @dev Getter to know the count of transactions.
     *  @return The count of transactions.
     */
    function getCountTransactions() public view returns (uint256) {
        return transactions.length;
    }

    /** @dev Gets the number of rounds of the specific transaction.
     *  @param _transactionID The ID of the transaction.
     *  @return The number of rounds.
     */
    function getNumberOfRounds(uint256 _transactionID) public view returns (uint256) {
        return uint256(transactions[_transactionID].roundCounter);
    }

    /** @dev Gets the contributions made by a party for a given round of the appeal.
     *  @param _transactionID The ID of the transaction.
     *  @param _round The position of the round.
     *  @param _contributor The address of the contributor.
     *  @return contributions The contributions.
     */
    function getContributions(
        uint256 _transactionID,
        uint256 _round,
        address _contributor
    ) public view returns(uint256[3] memory contributions) {
        Transaction storage transaction = transactions[_transactionID];
        Round storage round = transaction.rounds[_round];
        contributions = round.contributions[_contributor];
    }

    /** @dev Gets the information on a round of a transaction.
     *  @param _transactionID The ID of the transaction.
     *  @param _round The round to query.
     *  @return paidFees sideFunded feeRewards appealed The round information.
     */
    function getRoundInfo(uint256 _transactionID, uint256 _round)
        public
        view
        returns (
            uint256[3] memory paidFees,
            Party sideFunded,
            uint256 feeRewards,
            bool appealed
        )
    {
        Transaction storage transaction = transactions[_transactionID];
        Round storage round = transaction.rounds[_round];
        return (
            round.paidFees,
            round.sideFunded,
            round.feeRewards,
            _round != transaction.roundCounter - 1
        );
    }
}
