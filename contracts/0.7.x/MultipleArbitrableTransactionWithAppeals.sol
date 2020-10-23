/**
 *  @authors: [@unknownunknown1, @fnanni-0]
 *  @reviewers: [@ferittuncer]
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

    struct Transaction {
        address payable sender;
        address payable receiver;
        uint256 amount;
        uint256 timeoutPayment; // Time in seconds after which the transaction can be automatically executed if not disputed.
        uint256 disputeID; // If dispute exists, the ID of the dispute.
        uint256 senderFee; // Total fees paid by the sender.
        uint256 receiverFee; // Total fees paid by the receiver.
        uint256 lastInteraction; // Last interaction for the dispute procedure.
        Status status;
        uint256 ruling; // The ruling of the dispute, if any.
    }
    
    struct Round {
        uint256[3] paidFees; // Tracks the fees paid by each side in this round.
        bool[3] hasPaid; // True when the side has fully paid its fee. False otherwise.
        uint256 feeRewards; // Sum of reimbursable fees and stake rewards available to the parties that made contributions to the side that ultimately wins a dispute.
        mapping(address => uint256[3]) contributions; // Maps contributors to their contributions for each side.
    }

    /**
     * @dev Tracks the state of eventual disputes.
     */
    struct TransactionDispute {
        bool hasRuling; // Required to differentiate between having no ruling and a RefusedToRule ruling.
        uint128 transactionID; // The transaction ID.
        uint8 ruling; // The ruling given by the arbitrator.
    }

    IArbitrator public arbitrator; // Address of the arbitrator contract.
    bytes public arbitratorExtraData; // Extra data to set up the arbitration.
    uint256 public feeTimeout; // Time in seconds a party can take to pay arbitration fees before being considered unresponding and lose the dispute.
    
    uint256 public sharedStakeMultiplier; // Multiplier for calculating the appeal fee that must be paid by submitter in the case where there is no winner or loser (e.g. when the arbitrator ruled "refuse to arbitrate").
    uint256 public winnerStakeMultiplier; // Multiplier for calculating the appeal fee of the party that won the previous round.
    uint256 public loserStakeMultiplier; // Multiplier for calculating the appeal fee of the party that lost the previous round.

    /// @dev Stores the hashes of all transactions.
    bytes32[] public transactionHashes;

    /// @dev Maps a transactionID to its respective appeal rounds.
    mapping(uint256 => Round[]) public roundsByTransactionID;

    /// @dev Maps a disputeID to its respective transaction dispute.
    mapping (uint256 => TransactionDispute) public disputeIDtoTransactionDispute;

    // **************************** //
    // *          Events          * //
    // **************************** //

    /**
     * @dev To be emitted whenever a transaction state is updated.
     * @param _transactionID The ID of the changed transaction.
     * @param _transaction The full transaction data after update.
     */
    event TransactionStateUpdated(uint256 indexed _transactionID, Transaction _transaction);

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
    event TransactionCreated(uint256 _transactionID, address indexed _sender, address indexed _receiver, uint256 _amount);

    /** @dev To be emitted when a transaction is resolved, either by its execution, a timeout or because a ruling was enforced.
     *  @param _transactionID The ID of the respective transaction.
     *  @param _reason Short description of what caused the transaction to be solved. 'transaction-executed' | 'timeout-by-sender' | 'timeout-by-receiver' | 'ruling-enforced'
     *  @param _timestamp When the task was resolved.
     */
    event TransactionResolved(uint256 indexed _transactionID, string _reason, uint256 _timestamp);

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
    event AppealFeeContribution(uint256 indexed _transactionID, Party _party, address _contributor, uint256 _amount);

    // **************************** //
    // *    Arbitrable functions  * //
    // *    Modifying the state   * //
    // **************************** //

    /** @dev Constructor.
     *  @param _arbitrator The arbitrator of the contract.
     *  @param _arbitratorExtraData Extra data for the arbitrator.
     *  @param _feeTimeout Arbitration fee timeout for the parties.
     *  @param _sharedStakeMultiplier Multiplier of the appeal cost that submitter must pay for a round when there is no winner/loser in the previous round. In basis points.
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

    modifier onlyValidTransaction(uint256 _transactionID, Transaction memory _transaction) {
        require(
            transactionHashes[_transactionID - 1] == hashTransactionState(_transaction), 
            "Transaction doesn't match stored hash"
            );
        _;
    }

    /// @dev Using calldata as data location makes gas consumption more efficient when caller function also uses calldata.
    modifier onlyValidTransactionCD(uint256 _transactionID, Transaction calldata _transaction) {
        require(
            transactionHashes[_transactionID - 1] == hashTransactionStateCD(_transaction), 
            "Transaction doesn't match stored hash"
            );
        _;
    }

    /** @dev Create a transaction.
     *  @param _timeoutPayment Time after which a party can automatically execute the arbitrable transaction.
     *  @param _receiver The recipient of the transaction.
     *  @param _metaEvidence Link to the meta-evidence.
     *  @return transactionID The index of the transaction.
     */
    function createTransaction(
        uint256 _timeoutPayment,
        address payable _receiver,
        string calldata _metaEvidence
    ) public payable returns (uint256 transactionID) {
        
        Transaction memory transaction;
        transaction.sender = msg.sender;
        transaction.receiver = _receiver;
        transaction.amount = msg.value;
        transaction.timeoutPayment = _timeoutPayment;
        transaction.lastInteraction = block.timestamp;

        transactionHashes.push(hashTransactionState(transaction));
        transactionID = transactionHashes.length; // transactionID starts at 1. This way, TransactionDispute can check if a dispute exists by testing transactionID != 0.

        emit MetaEvidence(transactionID, _metaEvidence);
        emit TransactionCreated(transactionID, msg.sender, _receiver, msg.value);
        emit TransactionStateUpdated(transactionID, transaction);
    }

    /** @dev Pay receiver. To be called if the good or service is provided.
     *  @param _transactionID The index of the transaction.
     *  @param _transaction The transaction state.
     *  @param _amount Amount to pay in wei.
     */
    function pay(uint256 _transactionID, Transaction memory _transaction, uint256 _amount) public onlyValidTransaction(_transactionID, _transaction) {
        require(_transaction.sender == msg.sender, "The caller must be the sender.");
        require(_transaction.status == Status.NoDispute, "The transaction must not be disputed.");
        require(_amount <= _transaction.amount, "Maximum amount available for payment exceeded.");

        _transaction.receiver.transfer(_amount);
        _transaction.amount -= _amount;
        transactionHashes[_transactionID - 1] = hashTransactionState(_transaction);

        emit Payment(_transactionID, _amount, msg.sender);
        emit TransactionStateUpdated(_transactionID, _transaction);
    }

    /** @dev Reimburse sender. To be called if the good or service can't be fully provided.
     *  @param _transactionID The index of the transaction.
     *  @param _transaction The transaction state.
     *  @param _amountReimbursed Amount to reimburse in wei.
     */
    function reimburse(uint256 _transactionID, Transaction memory _transaction, uint256 _amountReimbursed) public onlyValidTransaction(_transactionID, _transaction) {
        require(_transaction.receiver == msg.sender, "The caller must be the receiver.");
        require(_transaction.status == Status.NoDispute, "The transaction must not be disputed.");
        require(_amountReimbursed <= _transaction.amount, "Maximum reimbursement available exceeded.");

        _transaction.sender.transfer(_amountReimbursed);
        _transaction.amount -= _amountReimbursed;
        transactionHashes[_transactionID - 1] = hashTransactionState(_transaction);

        emit Payment(_transactionID, _amountReimbursed, msg.sender);
        emit TransactionStateUpdated(_transactionID, _transaction);
    }

    /** @dev Transfer the transaction's amount to the receiver if the timeout has passed.
     *  @param _transactionID The index of the transaction.
     *  @param _transaction The transaction state.
     */
    function executeTransaction(uint256 _transactionID, Transaction memory _transaction) public onlyValidTransaction(_transactionID, _transaction) {
        require(block.timestamp - _transaction.lastInteraction >= _transaction.timeoutPayment, "The timeout has not passed yet.");
        require(_transaction.status == Status.NoDispute, "The transaction must not be disputed.");

        _transaction.receiver.transfer(_transaction.amount);
        _transaction.amount = 0;

        _transaction.status = Status.Resolved;

        transactionHashes[_transactionID - 1] = hashTransactionState(_transaction);
        emit TransactionStateUpdated(_transactionID, _transaction);
        emit TransactionResolved(_transactionID, "transaction-executed", block.timestamp);
    }

    /** @dev Pay the arbitration fee to raise a dispute. To be called by the sender. UNTRUSTED.
     *  Note that the arbitrator can have createDispute throw, which will make this function throw and therefore lead to a party being timed-out.
     *  This is not a vulnerability as the arbitrator can rule in favor of one party anyway.
     *  @param _transactionID The index of the transaction.
     *  @param _transaction The transaction state.
     */
    function payArbitrationFeeBySender(uint256 _transactionID, Transaction memory _transaction) public payable onlyValidTransaction(_transactionID, _transaction) {
        require(_transaction.status < Status.DisputeCreated, "Dispute has already been created or because the transaction has been executed.");
        require(msg.sender == _transaction.sender, "The caller must be the sender.");

        uint256 arbitrationCost = arbitrator.arbitrationCost(arbitratorExtraData);
        _transaction.senderFee += msg.value;
        // Require that the total pay at least the arbitration cost.
        require(_transaction.senderFee >= arbitrationCost, "The sender fee must cover arbitration costs.");

        _transaction.lastInteraction = block.timestamp;

        // The receiver still has to pay. This can also happen if he has paid, but arbitrationCost has increased.
        if (_transaction.receiverFee < arbitrationCost) {
            _transaction.status = Status.WaitingReceiver;
            emit HasToPayFee(_transactionID, Party.Receiver);
        } else { // The receiver has also paid the fee. We create the dispute.
            raiseDispute(_transactionID, _transaction, arbitrationCost);
        }

        transactionHashes[_transactionID - 1] = hashTransactionState(_transaction);
        emit TransactionStateUpdated(_transactionID, _transaction);
    }

    /** @dev Pay the arbitration fee to raise a dispute. To be called by the receiver. UNTRUSTED.
     *  Note that this function mirrors payArbitrationFeeBySender.
     *  @param _transactionID The index of the transaction.
     *  @param _transaction The transaction state.
     */
    function payArbitrationFeeByReceiver(uint256 _transactionID, Transaction memory _transaction) public payable onlyValidTransaction(_transactionID, _transaction) {
        require(_transaction.status < Status.DisputeCreated, "Dispute has already been created or because the transaction has been executed.");
        require(msg.sender == _transaction.receiver, "The caller must be the receiver.");
        
        uint256 arbitrationCost = arbitrator.arbitrationCost(arbitratorExtraData);
        _transaction.receiverFee += msg.value;
        // Require that the total paid to be at least the arbitration cost.
        require(_transaction.receiverFee >= arbitrationCost, "The receiver fee must cover arbitration costs.");

        _transaction.lastInteraction = block.timestamp;
        // The sender still has to pay. This can also happen if he has paid, but arbitrationCost has increased.
        if (_transaction.senderFee < arbitrationCost) {
            _transaction.status = Status.WaitingSender;
            emit HasToPayFee(_transactionID, Party.Sender);
        } else { // The sender has also paid the fee. We create the dispute.
            raiseDispute(_transactionID, _transaction, arbitrationCost);
        }

        transactionHashes[_transactionID - 1] = hashTransactionState(_transaction);
        emit TransactionStateUpdated(_transactionID, _transaction);
    }

    /** @dev Reimburse sender if receiver fails to pay the fee.
     *  @param _transactionID The index of the transaction.
     *  @param _transaction The transaction state.
     */
    function timeOutBySender(uint256 _transactionID, Transaction memory _transaction) public onlyValidTransaction(_transactionID, _transaction) {
        require(_transaction.status == Status.WaitingReceiver, "The transaction is not waiting on the receiver.");
        require(block.timestamp - _transaction.lastInteraction >= feeTimeout, "Timeout time has not passed yet.");

        if (_transaction.receiverFee != 0) {
            _transaction.receiver.send(_transaction.receiverFee);
            _transaction.receiverFee = 0;
        }

        _transaction.sender.send(_transaction.senderFee + _transaction.amount);
        _transaction.amount = 0;
        _transaction.senderFee = 0;
        _transaction.status = Status.Resolved;
        _transaction.ruling = uint256(Party.Sender);

        transactionHashes[_transactionID - 1] = hashTransactionState(_transaction);
        emit TransactionStateUpdated(_transactionID, _transaction);
        emit TransactionResolved(_transactionID, "timeout-by-sender", block.timestamp);
    }

    /** @dev Pay receiver if sender fails to pay the fee.
     *  @param _transactionID The index of the transaction.
     *  @param _transaction The transaction state.
     */
    function timeOutByReceiver(uint256 _transactionID, Transaction memory _transaction) public onlyValidTransaction(_transactionID, _transaction) {
        require(_transaction.status == Status.WaitingSender, "The transaction is not waiting on the sender.");
        require(block.timestamp - _transaction.lastInteraction >= feeTimeout, "Timeout time has not passed yet.");

        if (_transaction.senderFee != 0) {
            _transaction.sender.send(_transaction.senderFee);
            _transaction.senderFee = 0;
        }

        _transaction.receiver.send(_transaction.receiverFee + _transaction.amount);
        _transaction.amount = 0;
        _transaction.receiverFee = 0;
        _transaction.status = Status.Resolved;
        _transaction.ruling = uint256(Party.Receiver);

        transactionHashes[_transactionID - 1] = hashTransactionState(_transaction);
        emit TransactionStateUpdated(_transactionID, _transaction);
        emit TransactionResolved(_transactionID, "timeout-by-receiver", block.timestamp);
    }

    /** @dev Create a dispute. UNTRUSTED.
     *  @notice This function is internal and thus the transaction state validity is not checked. Caller functions MUST do the check before calling this function.
     *  @notice _transaction MUST be a reference (not a copy) because its state is modified. Caller functions MUST emit the TransactionStateUpdated event and update the hash.
     *  @param _transactionID The index of the transaction.
     *  @param _transaction The transaction state.
     *  @param _arbitrationCost Amount to pay the arbitrator.
     */
    function raiseDispute(uint256 _transactionID, Transaction memory _transaction, uint256 _arbitrationCost) internal {
        _transaction.status = Status.DisputeCreated;
        _transaction.disputeID = arbitrator.createDispute{value: _arbitrationCost}(AMOUNT_OF_CHOICES, arbitratorExtraData);
        roundsByTransactionID[_transactionID].push();
        TransactionDispute storage transactionDispute = disputeIDtoTransactionDispute[_transaction.disputeID];
        transactionDispute.transactionID = uint128(_transactionID);
        emit Dispute(arbitrator, _transaction.disputeID, _transactionID, _transactionID);

        // Refund sender if it overpaid.
        if (_transaction.senderFee > _arbitrationCost) {
            uint256 extraFeeSender = _transaction.senderFee - _arbitrationCost;
            _transaction.senderFee = _arbitrationCost;
            _transaction.sender.send(extraFeeSender);
        }

        // Refund receiver if it overpaid.
        if (_transaction.receiverFee > _arbitrationCost) {
            uint256 extraFeeReceiver = _transaction.receiverFee - _arbitrationCost;
            _transaction.receiverFee = _arbitrationCost;
            _transaction.receiver.send(extraFeeReceiver);
        }
    }

    /** @dev Submit a reference to evidence. EVENT.
     *  @param _transactionID The index of the transaction.
     *  @param _transaction The transaction state.
     *  @param _evidence A link to an evidence using its URI.
     */
    function submitEvidence(uint256 _transactionID, Transaction calldata _transaction, string calldata _evidence) public onlyValidTransactionCD(_transactionID, _transaction) {
        require(
            msg.sender == _transaction.sender || msg.sender == _transaction.receiver,
            "The caller must be the sender or the receiver."
        );
        require(
            _transaction.status < Status.Resolved,
            "Must not send evidence if the dispute is resolved."
        );

        emit Evidence(arbitrator, _transactionID, msg.sender, _evidence);
    }

    /** @dev Takes up to the total amount required to fund a side of an appeal. Reimburses the rest. Creates an appeal if both sides are fully funded.
     *  @param _transactionID The ID of the disputed transaction.
     *  @param _transaction The transaction state.
     *  @param _side The party that pays the appeal fee.
     */
    function fundAppeal(uint256 _transactionID, Transaction calldata _transaction, Party _side) public payable onlyValidTransactionCD(_transactionID, _transaction) {
        require(_side == Party.Sender || _side == Party.Receiver, "Wrong party.");
        require(_transaction.status == Status.DisputeCreated, "No dispute to appeal");
        require(arbitrator.disputeStatus(_transaction.disputeID) == IArbitrator.DisputeStatus.Appealable, "Dispute is not appealable.");

        (uint256 appealPeriodStart, uint256 appealPeriodEnd) = arbitrator.appealPeriod(_transaction.disputeID);
        require(block.timestamp >= appealPeriodStart && block.timestamp < appealPeriodEnd, "Funding must be made within the appeal period.");

        uint256 winner = arbitrator.currentRuling(_transaction.disputeID);
        uint256 multiplier;
        if (winner == uint256(_side)){
            multiplier = winnerStakeMultiplier;
        } else if (winner == 0){
            multiplier = sharedStakeMultiplier;
        } else {
            require(block.timestamp - appealPeriodStart < (appealPeriodEnd - appealPeriodStart)/2, "The loser must pay during the first half of the appeal period.");
            multiplier = loserStakeMultiplier;
        }

        Round storage round = roundsByTransactionID[_transactionID][roundsByTransactionID[_transactionID].length - 1];
        require(!round.hasPaid[uint256(_side)], "Appeal fee has already been paid.");

        uint256 appealCost = arbitrator.appealCost(_transaction.disputeID, arbitratorExtraData);
        uint256 totalCost = appealCost.addCap((appealCost.mulCap(multiplier)) / MULTIPLIER_DIVISOR);

        // Take up to the amount necessary to fund the current round at the current costs.
        uint256 contribution; // Amount contributed.
        uint256 remainingETH; // Remaining ETH to send back.
        (contribution, remainingETH) = calculateContribution(msg.value, totalCost.subCap(round.paidFees[uint256(_side)]));
        round.contributions[msg.sender][uint256(_side)] += contribution;
        round.paidFees[uint256(_side)] += contribution;

        emit AppealFeeContribution(_transactionID, _side, msg.sender, contribution);
        
        if (round.paidFees[uint256(_side)] >= totalCost) {
            round.hasPaid[uint256(_side)] = true;
            round.feeRewards += round.paidFees[uint256(_side)];
            emit HasPaidAppealFee(_transactionID, _side);
        }

        // Reimburse leftover ETH.
        msg.sender.send(remainingETH); // Deliberate use of send in order to not block the contract in case of reverting fallback.

        // Create an appeal if each side is funded.
        if (round.hasPaid[uint256(Party.Sender)] && round.hasPaid[uint256(Party.Receiver)]) {
            arbitrator.appeal{value: appealCost}(_transaction.disputeID, arbitratorExtraData);
            round.feeRewards = round.feeRewards.subCap(appealCost);
            roundsByTransactionID[_transactionID].push();
        }
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
    
    /** @dev Updates contributions of appeal rounds which are going to be withdrawn.
     *  @notice Caller functions MUST: (1) check that the transaction is valid and Resolved and (2) send the rewards to the _beneficiary.
     *  @param _beneficiary The address that made contributions.
     *  @param _transactionID The ID of the associated transaction.
     *  @param _round The round from which to withdraw.
     *  @param _finalRuling The final ruling of this transaction.
     *  @return reward The amount of wei available to withdraw from _round.
     */
    function _withdrawFeesAndRewards(address _beneficiary, uint256 _transactionID, uint256 _round, uint256 _finalRuling) internal returns(uint256 reward) {
        Round storage round = roundsByTransactionID[_transactionID][_round];
        uint256[3] storage contributionTo = round.contributions[_beneficiary];
        if (!round.hasPaid[uint256(Party.Sender)] || !round.hasPaid[uint256(Party.Receiver)]) {
            // Allow to reimburse if funding was unsuccessful.
            reward = contributionTo[uint256(Party.Sender)] + contributionTo[uint256(Party.Receiver)];
        } else if (_finalRuling == uint256(Party.None)) {
            // Reimburse unspent fees proportionally if there is no winner and loser.
            uint256 totalFeesPaid = round.paidFees[uint256(Party.Sender)] + round.paidFees[uint256(Party.Receiver)];
            uint256 totalBeneficiaryContributions = contributionTo[uint256(Party.Sender)] + contributionTo[uint256(Party.Receiver)];
            reward = totalFeesPaid > 0 ? (totalBeneficiaryContributions * round.feeRewards) / totalFeesPaid : 0;
        } else {
            // Reward the winner.
            reward = round.paidFees[_finalRuling] > 0
                ? (contributionTo[_finalRuling] * round.feeRewards) / round.paidFees[_finalRuling]
                : 0;
        }
        contributionTo[uint256(Party.Sender)] = 0;
        contributionTo[uint256(Party.Receiver)] = 0;
    }
    
    /** @dev Witdraws contributions of appeal rounds. Reimburses contributions if the appeal was not fully funded. If the appeal was fully funded, sends the fee stake rewards and reimbursements proportional to the contributions made to the winner of a dispute.
     *  @param _beneficiary The address that made contributions.
     *  @param _transactionID The ID of the associated transaction.
     *  @param _transaction The transaction state.
     *  @param _round The round from which to withdraw.
     */
    function withdrawFeesAndRewards(address payable _beneficiary, uint256 _transactionID, Transaction calldata _transaction, uint256 _round) public onlyValidTransactionCD(_transactionID, _transaction) {
        require(_transaction.status == Status.Resolved, "The transaction must be resolved.");
        uint256 reward = _withdrawFeesAndRewards(_beneficiary, _transactionID, _round, _transaction.ruling);
        _beneficiary.send(reward); // It is the user responsibility to accept ETH.
    }
    
    /** @dev Withdraws contributions of multiple appeal rounds at once. This function is O(n) where n is the number of rounds. This could exceed the gas limit, therefore this function should be used only as a utility and not be relied upon by other contracts.
     *  @param _beneficiary The address that made contributions.
     *  @param _transactionID The ID of the associated transaction.
     *  @param _transaction The transaction state.
     *  @param _cursor The round from where to start withdrawing.
     *  @param _count The number of rounds to iterate. If set to 0 or a value larger than the number of rounds, iterates until the last round.
     */
    function batchRoundWithdraw(address payable _beneficiary, uint256 _transactionID, Transaction calldata _transaction, uint256 _cursor, uint256 _count) public onlyValidTransactionCD(_transactionID, _transaction) {
        require(_transaction.status == Status.Resolved, "The transaction must be resolved.");

        uint256 reward;
        uint256 totalRounds = roundsByTransactionID[_transactionID].length;
        for (uint256 i = _cursor; i<totalRounds && (_count==0 || i<_cursor+_count); i++)
            reward += _withdrawFeesAndRewards(_beneficiary, _transactionID, i, _transaction.ruling);
        _beneficiary.send(reward); // It is the user responsibility to accept ETH.
    }

    /** @dev Give a ruling for a dispute. Must be called by the arbitrator.
     *  The purpose of this function is to ensure that the address calling it has the right to rule on the contract.
     *  @param _disputeID ID of the dispute in the Arbitrator contract.
     *  @param _ruling Ruling given by the arbitrator. Note that 0 is reserved for "Not able/wanting to make a decision".
     */
    function rule(uint256 _disputeID, uint256 _ruling) public override {
        require(msg.sender == address(arbitrator), "The caller must be the arbitrator.");
        require(_ruling <= AMOUNT_OF_CHOICES, "Invalid ruling.");

        TransactionDispute storage transactionDispute = disputeIDtoTransactionDispute[_disputeID];
        require(transactionDispute.transactionID != 0, "Dispute does not exist.");
        require(transactionDispute.hasRuling == false, " Dispute already resolved.");
        
        Round[] storage rounds = roundsByTransactionID[uint256(transactionDispute.transactionID)];
        Round storage round = rounds[rounds.length - 1];

        // If only one side paid its fees we assume the ruling to be in its favor.
        if (round.hasPaid[uint256(Party.Sender)] == true)
            transactionDispute.ruling = uint8(Party.Sender);
        else if (round.hasPaid[uint256(Party.Receiver)] == true)
            transactionDispute.ruling = uint8(Party.Receiver);
        else
            transactionDispute.ruling = uint8(_ruling);

        transactionDispute.hasRuling = true;
        emit Ruling(arbitrator, _disputeID, uint256(transactionDispute.ruling));
    }
    
    /** @dev Execute a ruling of a dispute. It reimburses the fee to the winning party.
     *  @param _transactionID The index of the transaction.
     *  @param _transaction The transaction state.
     */
    function executeRuling(uint256 _transactionID, Transaction memory _transaction) public onlyValidTransaction(_transactionID, _transaction) {
        require(_transaction.status == Status.DisputeCreated, "Invalid transaction status.");

        TransactionDispute storage transactionDispute = disputeIDtoTransactionDispute[_transaction.disputeID];
        require(transactionDispute.hasRuling, "Arbitrator has not ruled yet.");

        // Give the arbitration fee back.
        // Note that we use send to prevent a party from blocking the execution.
        if (transactionDispute.ruling == uint8(Party.Sender)) {
            _transaction.sender.send(_transaction.senderFee + _transaction.amount);
        } else if (transactionDispute.ruling == uint8(Party.Receiver)) {
            _transaction.receiver.send(_transaction.receiverFee + _transaction.amount);
        } else {
            uint256 split_amount = (_transaction.senderFee + _transaction.amount) / 2;
            _transaction.sender.send(split_amount);
            _transaction.receiver.send(split_amount);
        }

        _transaction.amount = 0;
        _transaction.senderFee = 0;
        _transaction.receiverFee = 0;
        _transaction.status = Status.Resolved;
        _transaction.ruling = uint256(transactionDispute.ruling);

        transactionHashes[_transactionID - 1] = hashTransactionState(_transaction);
        emit TransactionStateUpdated(_transactionID, _transaction);
        emit TransactionResolved(_transactionID, "ruling-enforced", block.timestamp);
    }

    // **************************** //
    // *     Constant getters     * //
    // **************************** //
    
    /** @dev Returns the sum of withdrawable wei from appeal rounds. This function is O(n), where n is the number of rounds of the transaction. This could exceed the gas limit, therefore this function should only be used for interface display and not by other contracts.
     *  @param _transactionID The index of the transaction.
     *  @param _transaction The transaction state.
     *  @param _beneficiary The contributor for which to query.
     *  @return total The total amount of wei available to withdraw.
     */
    function amountWithdrawable(uint256 _transactionID, Transaction calldata _transaction, address _beneficiary) public view onlyValidTransactionCD(_transactionID, _transaction) returns (uint256 total) {
        if (_transaction.status != Status.Resolved) return total;

        Round[] storage rounds = roundsByTransactionID[_transactionID];
        uint256 totalRounds = rounds.length;
        for (uint256 i = 0; i < totalRounds; i++) {
            Round storage round = rounds[i];
            if (!round.hasPaid[uint256(Party.Sender)] || !round.hasPaid[uint256(Party.Receiver)]) {
                total += round.contributions[_beneficiary][uint256(Party.Sender)] + round.contributions[_beneficiary][uint256(Party.Receiver)];
            } else if (_transaction.ruling == uint256(Party.None)) {
                uint256 totalFeesPaid = round.paidFees[uint256(Party.Sender)] + round.paidFees[uint256(Party.Receiver)];
                uint256 totalBeneficiaryContributions = round.contributions[_beneficiary][uint256(Party.Sender)] + round.contributions[_beneficiary][uint256(Party.Receiver)];
                total += totalFeesPaid > 0 ? (totalBeneficiaryContributions * round.feeRewards) / totalFeesPaid : 0;
            } else {
                total += round.paidFees[uint256(_transaction.ruling)] > 0
                    ? (round.contributions[_beneficiary][uint256(_transaction.ruling)] * round.feeRewards) / round.paidFees[uint256(_transaction.ruling)]
                    : 0;
            }
        }
    }

    /** @dev Getter to know the count of transactions.
     *  @return The count of transactions.
     */
    function getCountTransactions() public view returns (uint256) {
        return transactionHashes.length;
    }

    /** @dev Gets the number of rounds of the specific transaction.
     *  @param _transactionID The ID of the transaction.
     *  @return The number of rounds.
     */
    function getNumberOfRounds(uint256 _transactionID) public view returns (uint256) {
        return roundsByTransactionID[_transactionID].length;
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
        Round storage round = roundsByTransactionID[_transactionID][_round];
        contributions = round.contributions[_contributor];
    }

    /** @dev Gets the information on a round of a transaction.
     *  @param _transactionID The ID of the transaction.
     *  @param _round The round to query.
     *  @return paidFees hasPaid feeRewards The round information.
     */
    function getRoundInfo(uint256 _transactionID, uint256 _round)
        public
        view
        returns (
            uint256[3] memory paidFees,
            bool[3] memory hasPaid,
            uint256 feeRewards
        )
    {
        Round storage round = roundsByTransactionID[_transactionID][_round];
        return (
            round.paidFees,
            round.hasPaid,
            round.feeRewards
        );
    }

    /**
     * @dev Gets the hashed version of the transaction state.
     * @notice If the caller function is using a Transaction object stored in calldata, this function is unnecessarily expensive, use hashTransactionStateCD instead.
     * @param _transaction The transaction state.
     * @return The hash of the transaction state.
     */
    function hashTransactionState(Transaction memory _transaction) public pure returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(
                    _transaction.sender,
                    _transaction.receiver,
                    _transaction.amount,
                    _transaction.timeoutPayment,
                    _transaction.disputeID,
                    _transaction.senderFee,
                    _transaction.receiverFee,
                    _transaction.lastInteraction,
                    _transaction.status,
                    _transaction.ruling
                )
            );
    }

    /**
     * @dev Gets the hashed version of the transaction state.
     * @notice this function is cheap (and can only be used) when the caller function is using a Transaction object stored in calldata
     * @param _transaction The transaction state.
     * @return The hash of the transaction state.
     */
    function hashTransactionStateCD(Transaction calldata _transaction) public pure returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(
                    _transaction.sender,
                    _transaction.receiver,
                    _transaction.amount,
                    _transaction.timeoutPayment,
                    _transaction.disputeID,
                    _transaction.senderFee,
                    _transaction.receiverFee,
                    _transaction.lastInteraction,
                    _transaction.status,
                    _transaction.ruling
                )
            );
    }
}