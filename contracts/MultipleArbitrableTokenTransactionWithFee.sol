// SPDX-License-Identifier: MIT

/**
 *  @authors: [@unknownunknown1, @fnanni-0, @shalzz, @remedcu]
 *  @reviewers: []
 *  @auditors: []
 *  @bounties: []
 */

pragma solidity 0.8.9;

import "@kleros/erc-792/contracts/IArbitrable.sol";
import "@kleros/erc-792/contracts/IArbitrator.sol";
import "@kleros/erc-792/contracts/erc-1497/IEvidence.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./libraries/CappedMath.sol";

/** @title Multiple Arbitrable ERC20 Token Transaction
 *  This is a contract for multiple arbitrated token transactions which can
 *  be reversed by an arbitrator.
 *  This can be used for buying goods, services and for paying freelancers.
 *  Parties are identified as "sender" and "receiver".
 *  This version of the contract supports appeal crowdfunding and platform fees.
 *  A fee is associated with each successful payment to receiver.
 *  Note that the contract expects the tokens to have standard ERC20 behaviour.
 *  The tokens that don't conform to this type of behaviour should be filtered by the UI.
 *  Tokens should not reenter or allow recipients to refuse the transfer.
 *  Also note that for ETH send() function is used deliberately instead of transfer() 
 *  to avoid blocking the flow with reverting fallback.
 */
contract MultipleArbitrableTokenTransactionWitFee is IArbitrable, IEvidence {
    using CappedMath for uint256;

    // **************************** //
    // *    Contract variables    * //
    // **************************** //

    uint256 public constant AMOUNT_OF_CHOICES = 2;
    uint256 public constant MULTIPLIER_DIVISOR = 10000; // Divisor parameter for multipliers.

    enum Party {
        None,
        Sender,
        Receiver
    }
    enum Status {
        NoDispute,
        WaitingSettlementSender,
        WaitingSettlementReceiver,
        WaitingSender,
        WaitingReceiver,
        DisputeCreated,
        Resolved
    }
    enum Resolution {
        TransactionExecuted,
        TimeoutBySender,
        TimeoutByReceiver,
        RulingEnforced,
        SettlementReached
    }

    struct Transaction {
        address payable sender;
        address payable receiver;
        uint256 amount;
        uint256 settlementSender; // Settlement amount proposed by the sender
        uint256 settlementReceiver; // Settlement amount proposed by the receiver
        IERC20 token;
        uint256 deadline; // Timestamp at which the transaction can be automatically executed if not disputed.
        uint256 disputeID; // If dispute exists, the ID of the dispute.
        uint256 senderFee; // Total arbitration fees paid by the sender.
        uint256 receiverFee; // Total arbitration fees paid by the receiver.
        uint256 lastInteraction; // Last interaction for the dispute procedure.
        Status status;
    }

    struct Round {
        uint256[3] paidFees; // Tracks the fees paid in this round in the form paidFees[side].
        bool[3] hasPaid; // True if the fees for this particular side have been fully paid in the form hasPaid[side].
        mapping(address => uint256[3]) contributions; // Maps contributors to their contributions for each side in the form contributions[address][side].
        uint256 feeRewards; // Sum of reimbursable appeal fees available to the parties that made contributions to the side that ultimately wins a dispute.
        uint256[] fundedSides; // Stores the sides that are fully funded.
    }

    /**
     * @dev Tracks the state of eventual disputes.
     */
    struct TransactionDispute {
        uint256 transactionID; // The transaction ID.
        bool hasRuling; // Required to differentiate between having no ruling and a RefusedToRule ruling.
        Party ruling; // The ruling given by the arbitrator.
    }

    struct FeeRecipientData {
	    address feeRecipient; // Address which receives a share of receiver payment.
        uint16 feeRecipientBasisPoint; // The share of fee to be received by the feeRecipient, in basis points. Note that this value shouldn't exceed Divisor.
    }

    IArbitrator public immutable arbitrator; // Address of the arbitrator contract. TRUSTED.
    bytes public arbitratorExtraData; // Extra data to set up the arbitration.
    // Time in seconds a party can take to pay arbitration fees before being
    // considered unresponsive and lose the dispute.
    uint256 public immutable feeTimeout;

    // Time in seconds a party can take to accept or propose a settlement
    // before being considered unresponsive and the case can be arbitrated.
    uint256 public immutable settlementTimeout;

    // Multiplier for calculating the appeal fee that must be paid by the
    // submitter in the case where there is no winner or loser
    // (e.g. when the arbitrator ruled "refuse to arbitrate").
    uint256 public immutable sharedStakeMultiplier;
    // Multiplier for calculating the appeal fee of the party that won the previous round.
    uint256 public immutable winnerStakeMultiplier;
    // Multiplier for calculating the appeal fee of the party that lost the previous round.
    uint256 public immutable loserStakeMultiplier;

    FeeRecipientData public feeRecipientData;

    /// @dev Stores the hashes of all transactions.
    bytes32[] public transactionHashes;
    
    /// @dev Maps a transactionID to its respective appeal rounds.
    mapping(uint256 => Round[]) public roundsByTransactionID;

    /// @dev Maps a disputeID to its respective transaction dispute.
    mapping(uint256 => TransactionDispute) public disputeIDtoTransactionDispute;

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

    /** @dev To be emitted when a fee is received by the feeRecipient in Token.
     *  @param _transactionID The index of the transaction.
     *  @param _amount The amount paid.
     *  @param _token The Token Address.
     */
    event FeeRecipientPaymentInToken(uint256 indexed _transactionID, uint256 _amount, IERC20 _token);

    /** @dev To be emitted when a feeRecipient is changed.
     *  @param _oldFeeRecipient Previous feeRecipient.
     *  @param _newFeeRecipient Current feeRecipient.
     */
    event FeeRecipientChanged(address indexed _oldFeeRecipient, address indexed _newFeeRecipient);

    /** @dev To be emitted when feeRecipientBasisPoint is changed.
     *  @param _oldFeeRecipientBasisPoint Previous value of feeRecipientBasisPoint.
     *  @param _newFeeRecipientBasisPoint Current value of feeRecipientBasisPoint.
     */
    event FeeBasisPointChanged(uint16 _oldFeeRecipientBasisPoint, uint16 _newFeeRecipientBasisPoint);

    /** @dev Indicate that a party has to pay a fee or would otherwise be considered as losing.
     *  @param _transactionID The index of the transaction.
     *  @param _party The party who has to pay.
     */
    event HasToPayFee(uint256 indexed _transactionID, Party _party);

    /** @dev Emitted when a transaction is created.
     *  @param _transactionID The index of the transaction.
     *  @param _sender The address of the sender.
     *  @param _receiver The address of the receiver.
     *  @param _token The token address.
     *  @param _amount The initial amount in the transaction.
     */
    event TransactionCreated(
        uint256 indexed _transactionID,
        address indexed _sender,
        address indexed _receiver,
        IERC20 _token,
        uint256 _amount
    );

    /** @dev To be emitted when a transaction is resolved, either by its execution,
     *       a timeout or because a ruling was enforced.
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
    event AppealContribution(
        uint256 indexed _transactionID,
        Party _party,
        address _contributor,
        uint256 _amount
    );

    // **************************** //
    // *    Arbitrable functions  * //
    // *    Modifying the state   * //
    // **************************** //

    /** @dev Constructor.
     *  @param _arbitrator The arbitrator of the contract.
     *  @param _arbitratorExtraData Extra data for the arbitrator.
     *  @param _feeRecipient Address which receives a share of receiver payment.
     *  @param _feeRecipientBasisPoint The share of fee to be received by the feeRecipient.
     *  @param _feeTimeout Arbitration fee timeout for the parties.
     *  @param _settlementTimeout Settlement timeout for the parties.
     *  @param _sharedStakeMultiplier Multiplier of the appeal cost that the
     *  submitter must pay for a round when there is no winner/loser in
     *  the previous round. In basis points.
     *  @param _winnerStakeMultiplier Multiplier of the appeal cost that the winner
     *  has to pay for a round. In basis points.
     *  @param _loserStakeMultiplier Multiplier of the appeal cost that the loser
     *  has to pay for a round. In basis points.
     */
    constructor(
        IArbitrator _arbitrator,
        bytes memory _arbitratorExtraData,
        address _feeRecipient,
        uint16 _feeRecipientBasisPoint,
        uint256 _feeTimeout,
        uint256 _settlementTimeout,
        uint256 _sharedStakeMultiplier,
        uint256 _winnerStakeMultiplier,
        uint256 _loserStakeMultiplier
    ) {
        arbitrator = _arbitrator;
        arbitratorExtraData = _arbitratorExtraData;
        feeRecipientData.feeRecipient = _feeRecipient;
        // Basis point being set higher than 10000 will result in underflow, 
        // but it's the responsibility of the deployer of the contract.
        feeRecipientData.feeRecipientBasisPoint = _feeRecipientBasisPoint;
        feeTimeout = _feeTimeout;
        settlementTimeout = _settlementTimeout;
        sharedStakeMultiplier = _sharedStakeMultiplier;
        winnerStakeMultiplier = _winnerStakeMultiplier;
        loserStakeMultiplier = _loserStakeMultiplier;
    }

    modifier onlyValidTransaction(uint256 _transactionID, Transaction memory _transaction) {
        require(
            transactionHashes[_transactionID - 1] == hashTransactionState(_transaction),
            "Transaction doesn't match stored hash."
        );
        _;
    }

    /// @dev Using calldata as data location makes gas consumption more efficient
    ///      when caller function also uses calldata.
    modifier onlyValidTransactionCD(uint256 _transactionID, Transaction calldata _transaction) {
        require(
            transactionHashes[_transactionID - 1] == hashTransactionStateCD(_transaction),
            "Transaction doesn't match stored hash."
        );
        _;
    }
    
    /** @dev Change Fee Recipient.
     *  @param _newFeeRecipient Address of the new Fee Recipient.
     */
    function changeFeeRecipient(address _newFeeRecipient) external {
        require(msg.sender == feeRecipientData.feeRecipient, "The caller must be the current Fee Recipient");
        feeRecipientData.feeRecipient = _newFeeRecipient;

        emit FeeRecipientChanged(msg.sender, _newFeeRecipient);
    }

    /** @dev Change feeRecipientBasisPoint.
     *  @param _newFeeRecipientBasisPoint Value of the new feeRecipientBasisPoint.
     */
    function changeFeeRecipientBasisPoint(uint16 _newFeeRecipientBasisPoint) external {
        require(msg.sender == feeRecipientData.feeRecipient, "The caller must be the current Fee Recipient");

        emit FeeBasisPointChanged(feeRecipientData.feeRecipientBasisPoint, _newFeeRecipientBasisPoint);
        feeRecipientData.feeRecipientBasisPoint = _newFeeRecipientBasisPoint;      
    }

    /** @dev Create a transaction. UNTRUSTED.
     *  @param _amount The amount of tokens in this transaction.
     *  @param _token The ERC20 token contract.
     *  @param _timeoutPayment Time after which a party automatically loses a dispute.
     *  @param _receiver The recipient of the transaction.
     *  @param _metaEvidence Link to the meta-evidence.
     *  @return transactionID The index of the transaction.
     */
    function createTransaction(
        uint256 _amount,
        IERC20 _token,
        uint256 _timeoutPayment,
        address payable _receiver,
        string calldata _metaEvidence
    ) external returns (uint256 transactionID) {
        // Transfers token from sender wallet to contract.
        require(
            _token.transferFrom(msg.sender, address(this), _amount),
            "Sender does not have enough approved funds."
        );
        require(
            _amount.mulCap(feeRecipientData.feeRecipientBasisPoint) >= MULTIPLIER_DIVISOR, 
            "Amount too low to pay fee."
        );

        Transaction memory transaction;
        transaction.sender = payable(msg.sender);
        transaction.receiver = _receiver;
        transaction.amount = _amount;
        transaction.token = _token;
        transaction.deadline = block.timestamp.addCap(_timeoutPayment);

        transactionHashes.push(hashTransactionState(transaction));
        // transactionID starts at 1. This way, TransactionDispute can check if
        // a dispute exists by testing transactionID != 0.
        transactionID = transactionHashes.length;

        emit TransactionCreated(transactionID, msg.sender, _receiver, _token, _amount);
        emit TransactionStateUpdated(transactionID, transaction);
        emit MetaEvidence(transactionID, _metaEvidence);
    }

    /** @notice Pay receiver. To be called if the good or service is provided.
     *  Can only be called by the sender.
     *  @dev UNTRUSTED
     *  @param _transactionID The index of the transaction.
     *  @param _transaction The transaction state.
     *  @param _amount Amount to pay in wei.
     */
    function pay(
        uint256 _transactionID,
        Transaction memory _transaction,
        uint256 _amount
    ) external onlyValidTransaction(_transactionID, _transaction) {
        require(_transaction.sender == msg.sender, "The caller must be the sender.");
        require(_transaction.status == Status.NoDispute, "The transaction must not be disputed.");
        require(_amount <= _transaction.amount, "Maximum amount available for payment exceeded.");

        _transaction.amount -= _amount;
        transactionHashes[_transactionID - 1] = hashTransactionState(_transaction);

        uint256 feeAmount = calculateFeeRecipientAmount(_amount);
        // Tokens should not reenter or allow recipients to refuse the transfer.
        require(
            _transaction.token.transfer(feeRecipientData.feeRecipient, feeAmount),
            "The `transfer` function must not fail."
        );

        require(
            _transaction.token.transfer(_transaction.receiver, _amount - feeAmount),
            "The `transfer` function must not fail."
        );
        emit Payment(_transactionID, _amount - feeAmount, msg.sender);
        emit FeeRecipientPaymentInToken(_transactionID, feeAmount, _transaction.token);
        emit TransactionStateUpdated(_transactionID, _transaction);
    }

    /** @notice Reimburse sender. To be called if the good or service can't be fully provided.
     *  Can only be called by the receiver.
     *  @dev UNTRUSTED
     *  @param _transactionID The index of the transaction.
     *  @param _transaction The transaction state.
     *  @param _amountReimbursed Amount to reimburse in wei.
     */
    function reimburse(
        uint256 _transactionID,
        Transaction memory _transaction,
        uint256 _amountReimbursed
    ) external onlyValidTransaction(_transactionID, _transaction) {
        require(_transaction.receiver == msg.sender, "The caller must be the receiver.");
        require(_transaction.status == Status.NoDispute, "The transaction must not be disputed.");
        require(
            _amountReimbursed <= _transaction.amount,
            "Maximum reimbursement available exceeded."
        );

        _transaction.amount -= _amountReimbursed;
        transactionHashes[_transactionID - 1] = hashTransactionState(_transaction);

        require(
            _transaction.token.transfer(_transaction.sender, _amountReimbursed),
            "The `transfer` function must not fail."
        );
        emit Payment(_transactionID, _amountReimbursed, msg.sender);
        emit TransactionStateUpdated(_transactionID, _transaction);
    }

    /** @dev Transfer the transaction's amount to the receiver if the timeout has passed. UNTRUSTED
     *  @param _transactionID The index of the transaction.
     *  @param _transaction The transaction state.
     */
    function executeTransaction(uint256 _transactionID, Transaction memory _transaction)
        external
        onlyValidTransaction(_transactionID, _transaction)
    {
        require(block.timestamp >= _transaction.deadline, "Deadline not passed.");
        require(_transaction.status == Status.NoDispute, "The transaction must not be disputed.");

        uint256 amount = _transaction.amount;
        _transaction.amount = 0;
        _transaction.status = Status.Resolved;
        transactionHashes[_transactionID - 1] = hashTransactionState(_transaction);

        uint256 feeAmount = calculateFeeRecipientAmount(amount);
        require(
            _transaction.token.transfer(feeRecipientData.feeRecipient, feeAmount),
            "The `transfer` function must not fail."
        );

        require(
            _transaction.token.transfer(_transaction.receiver, amount - feeAmount),
            "The `transfer` function must not fail."
        );

        emit Payment(_transactionID, amount - feeAmount, _transaction.sender);
        emit FeeRecipientPaymentInToken(_transactionID, feeAmount, _transaction.token);
        emit TransactionStateUpdated(_transactionID, _transaction);
        emit TransactionResolved(_transactionID, Resolution.TransactionExecuted);
    }

    /** @notice Propose a settlement as a compromise from the initial terms to the other party.
     *  @dev A party can only propose a settlement again after the other party has
     *  done so as well to prevent front running/griefing issues.
     *  @param _transactionID The index of the transaction.
     *  @param _transaction The transaction state.
     *  @param _amount The settlement amount.
     */
    function proposeSettlement(
        uint256 _transactionID,
        Transaction memory _transaction,
        uint256 _amount
    ) external onlyValidTransaction(_transactionID, _transaction) {
        require(
            block.timestamp < _transaction.deadline || _transaction.status != Status.NoDispute,
            "Transaction expired"
        );
        require(
            _transaction.status < Status.WaitingSender,
            "Transaction already escalated for arbitration"
        );

        require(
            _amount <= _transaction.amount,
            "Settlement amount cannot be more that the initial amount"
        );

        if (_transaction.status == Status.WaitingSettlementSender) {
            require(msg.sender == _transaction.sender, "The caller must be the sender.");
            _transaction.settlementSender = _amount;
            _transaction.status = Status.WaitingSettlementReceiver;
        } else if (_transaction.status == Status.WaitingSettlementReceiver) {
            require(msg.sender == _transaction.receiver, "The caller must be the receiver.");
            _transaction.settlementReceiver = _amount;
            _transaction.status = Status.WaitingSettlementSender;
        } else {
            if (msg.sender == _transaction.sender) {
                _transaction.settlementSender = _amount;
                _transaction.status = Status.WaitingSettlementReceiver;
            } else if (msg.sender == _transaction.receiver) {
                _transaction.settlementReceiver = _amount;
                _transaction.status = Status.WaitingSettlementSender;
            } else revert("Only the sender or receiver addresses are authorized");
        }

        _transaction.lastInteraction = block.timestamp;
        transactionHashes[_transactionID - 1] = hashTransactionState(_transaction);
        emit TransactionStateUpdated(_transactionID, _transaction);
    }

    /** @notice Accept a settlement proposed by the other party.
     *  @param _transactionID The index of the transaction.
     *  @param _transaction The transaction state.
     */
    function acceptSettlement(uint256 _transactionID, Transaction memory _transaction)
        external
        onlyValidTransaction(_transactionID, _transaction)
    {
        uint256 settlementAmount;
        if (_transaction.status == Status.WaitingSettlementSender) {
            require(msg.sender == _transaction.sender, "The caller must be the sender.");
            settlementAmount = _transaction.settlementReceiver;
        } else if (_transaction.status == Status.WaitingSettlementReceiver) {
            require(msg.sender == _transaction.receiver, "The caller must be the receiver.");
            settlementAmount = _transaction.settlementSender;
        } else revert("No settlement proposed to accept or tx already disputed/resolved.");

        uint256 remainingAmount = _transaction.amount - settlementAmount;

        _transaction.amount = 0;
        _transaction.settlementSender = 0;
        _transaction.settlementReceiver = 0;

        _transaction.status = Status.Resolved;
        transactionHashes[_transactionID - 1] = hashTransactionState(_transaction); // solhint-disable-line

        uint256 feeAmount = calculateFeeRecipientAmount(settlementAmount);
        require(
            _transaction.token.transfer(feeRecipientData.feeRecipient, feeAmount),
            "The `transfer` function must not fail."
        );

        require(
            _transaction.token.transfer(_transaction.sender, remainingAmount),
            "The `transfer` function must not fail."
        );
        require(
            _transaction.token.transfer(_transaction.receiver, settlementAmount - feeAmount),
            "The `transfer` function must not fail."
        );

        emit Payment(_transactionID, settlementAmount - feeAmount, _transaction.sender);
        emit FeeRecipientPaymentInToken(_transactionID, feeAmount, _transaction.token);
        emit TransactionStateUpdated(_transactionID, _transaction);
        emit TransactionResolved(_transactionID, Resolution.SettlementReached);
    }

    /** @dev Pay the arbitration fee to raise a dispute. To be called by the sender. UNTRUSTED.
     *  Note that the arbitrator can have createDispute throw, which will make
     *  this function throw and therefore lead to a party being timed-out.
     *  This is not a vulnerability as the arbitrator can rule in favor of one party anyway.
     *  @param _transactionID The index of the transaction.
     *  @param _transaction The transaction state.
     */
    function payArbitrationFeeBySender(uint256 _transactionID, Transaction memory _transaction)
        external
        payable
        onlyValidTransaction(_transactionID, _transaction)
    {
        require(
            _transaction.status == Status.WaitingSettlementSender ||
                _transaction.status == Status.WaitingSettlementReceiver ||
                _transaction.status == Status.WaitingSender,
            "Settlement not attempted first or the transaction already executed/disputed."
        );

        // Allow the other party enough time to respond to a settlement before
        // allowing the proposer to raise a dispute.
        if (_transaction.status == Status.WaitingSettlementReceiver) {
            require(
                block.timestamp - _transaction.lastInteraction >= settlementTimeout,
                "Settlement period has not timed out yet."
            );
        }

        require(msg.sender == _transaction.sender, "The caller must be the sender.");

        uint256 arbitrationCost = arbitrator.arbitrationCost(arbitratorExtraData);
        _transaction.senderFee += msg.value;
        // Require that the total paid to be at least the arbitration cost.
        require(
            _transaction.senderFee >= arbitrationCost,
            "The sender fee must cover arbitration costs."
        );

        _transaction.lastInteraction = block.timestamp;
        // The receiver still has to pay. This can also happen if he has paid, but `arbitrationCost` has increased.
        if (_transaction.receiverFee < arbitrationCost) {
            _transaction.status = Status.WaitingReceiver;
            emit HasToPayFee(_transactionID, Party.Receiver);
        } else {
            // The receiver has also paid the fee. We create the dispute.
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
    function payArbitrationFeeByReceiver(uint256 _transactionID, Transaction memory _transaction)
        external
        payable
        onlyValidTransaction(_transactionID, _transaction)
    {
        require(
            _transaction.status == Status.WaitingSettlementSender ||
                _transaction.status == Status.WaitingSettlementReceiver ||
                _transaction.status == Status.WaitingReceiver,
            "Settlement not attempted first or the transaction already executed/disputed."
        );

        // Allow the other party enough time to respond to a settlement before
        // allowing the proposer to raise a dispute.
        if (_transaction.status == Status.WaitingSettlementSender) {
            require(
                block.timestamp - _transaction.lastInteraction >= settlementTimeout,
                "Settlement period has not timed out yet."
            );
        }

        require(msg.sender == _transaction.receiver, "The caller must be the receiver.");

        uint256 arbitrationCost = arbitrator.arbitrationCost(arbitratorExtraData);
        _transaction.receiverFee += msg.value;
        // Require that the total paid to be at least the arbitration cost.
        require(
            _transaction.receiverFee >= arbitrationCost,
            "The receiver fee must cover arbitration costs."
        );

        _transaction.lastInteraction = block.timestamp;
        // The sender still has to pay. This can also happen if he has paid, but arbitrationCost has increased.
        if (_transaction.senderFee < arbitrationCost) {
            _transaction.status = Status.WaitingSender;
            emit HasToPayFee(_transactionID, Party.Sender);
        } else {
            // The sender has also paid the fee. We create the dispute.
            raiseDispute(_transactionID, _transaction, arbitrationCost);
        }

        transactionHashes[_transactionID - 1] = hashTransactionState(_transaction);
        emit TransactionStateUpdated(_transactionID, _transaction);
    }

    /** @dev Reimburse sender if receiver fails to pay the fee. UNTRUSTED
     *  @param _transactionID The index of the transaction.
     *  @param _transaction The transaction state.
     */
    function timeOutBySender(uint256 _transactionID, Transaction memory _transaction)
        external
        onlyValidTransaction(_transactionID, _transaction)
    {
        require(
            _transaction.status == Status.WaitingReceiver,
            "The transaction is not waiting on the receiver."
        );
        require(
            block.timestamp - _transaction.lastInteraction >= feeTimeout,
            "Timeout time has not passed yet."
        );

        if (_transaction.receiverFee != 0) {
            _transaction.receiver.send(_transaction.receiverFee); // It is the user responsibility to accept ETH.
            _transaction.receiverFee = 0;
        }

        uint256 amount = _transaction.amount;
        uint256 senderFee = _transaction.senderFee;

        _transaction.amount = 0;
        _transaction.settlementSender = 0;
        _transaction.settlementReceiver = 0;
        _transaction.senderFee = 0;
        _transaction.status = Status.Resolved;
        transactionHashes[_transactionID - 1] = hashTransactionState(_transaction); // solhint-disable-line

        require(
            _transaction.token.transfer(_transaction.sender, amount),
            "The `transfer` function must not fail."
        );
        _transaction.sender.send(senderFee); // It is the user responsibility to accept ETH.
        emit TransactionStateUpdated(_transactionID, _transaction);
        emit TransactionResolved(_transactionID, Resolution.TimeoutBySender);
    }

    /** @dev Pay receiver if sender fails to pay the fee. UNTRUSTED
     *  @param _transactionID The index of the transaction.
     *  @param _transaction The transaction state.
     */
    function timeOutByReceiver(uint256 _transactionID, Transaction memory _transaction)
        external
        onlyValidTransaction(_transactionID, _transaction)
    {
        require(
            _transaction.status == Status.WaitingSender,
            "The transaction is not waiting on the sender."
        );
        require(
            block.timestamp - _transaction.lastInteraction >= feeTimeout,
            "Timeout time has not passed yet."
        );

        if (_transaction.senderFee != 0) {
            _transaction.sender.send(_transaction.senderFee); // It is the user responsibility to accept ETH.
            _transaction.senderFee = 0;
        }

        uint256 amount = _transaction.amount;
        uint256 receiverFee = _transaction.receiverFee;

        _transaction.amount = 0;
        _transaction.settlementSender = 0;
        _transaction.settlementReceiver = 0;
        _transaction.receiverFee = 0;
        _transaction.status = Status.Resolved;
        transactionHashes[_transactionID - 1] = hashTransactionState(_transaction); // solhint-disable-line

        uint256 feeAmount = calculateFeeRecipientAmount(amount);
        require(
            _transaction.token.transfer(feeRecipientData.feeRecipient, feeAmount),
            "The `transfer` function must not fail."
        );
        require(
            _transaction.token.transfer(_transaction.receiver, amount - feeAmount),
            "The `transfer` function must not fail."
        );
        _transaction.receiver.send(receiverFee); // It is the user responsibility to accept ETH.

        emit FeeRecipientPaymentInToken(_transactionID, feeAmount, _transaction.token);
        emit TransactionStateUpdated(_transactionID, _transaction);
        emit TransactionResolved(_transactionID, Resolution.TimeoutByReceiver);
    }

    /** @dev Create a dispute. UNTRUSTED.
     *  This function is internal and thus the transaction state validity is not checked.
     *  Caller functions MUST do the check before calling this function.
     *  _transaction MUST be a reference (not a copy) because its state is modified.
     *  Caller functions MUST emit the TransactionStateUpdated event and update the hash.
     *  @param _transactionID The index of the transaction.
     *  @param _transaction The transaction state.
     *  @param _arbitrationCost Amount to pay the arbitrator.
     */
    function raiseDispute(
        uint256 _transactionID,
        Transaction memory _transaction,
        uint256 _arbitrationCost
    ) internal {
        _transaction.status = Status.DisputeCreated;
        _transaction.disputeID = arbitrator.createDispute{ value: _arbitrationCost }(
            AMOUNT_OF_CHOICES,
            arbitratorExtraData
        );
        roundsByTransactionID[_transactionID].push();
        TransactionDispute storage transactionDispute = disputeIDtoTransactionDispute[
            _transaction.disputeID
        ];
        transactionDispute.transactionID = _transactionID;
        emit Dispute(arbitrator, _transaction.disputeID, _transactionID, _transactionID);

        // Refund sender if it overpaid.
        if (_transaction.senderFee > _arbitrationCost) {
            uint256 extraFeeSender = _transaction.senderFee - _arbitrationCost;
            _transaction.senderFee = _arbitrationCost;
            _transaction.sender.send(extraFeeSender); // It is the user responsibility to accept ETH.
        }

        // Refund receiver if it overpaid.
        if (_transaction.receiverFee > _arbitrationCost) {
            uint256 extraFeeReceiver = _transaction.receiverFee - _arbitrationCost;
            _transaction.receiverFee = _arbitrationCost;
            _transaction.receiver.send(extraFeeReceiver); // It is the user responsibility to accept ETH.
        }
    }

    /** @dev Submit a reference to evidence. EVENT.
     *  @param _transactionID The index of the transaction.
     *  @param _transaction The transaction state.
     *  @param _evidence A link to an evidence using its URI.
     */
    function submitEvidence(
        uint256 _transactionID,
        Transaction calldata _transaction,
        string calldata _evidence
    ) external onlyValidTransactionCD(_transactionID, _transaction) {
        require(
            _transaction.status < Status.Resolved,
            "Must not send evidence if the dispute is resolved."
        );

        emit Evidence(arbitrator, _transactionID, msg.sender, _evidence);
    }

    /** @dev Takes up to the total amount required to fund a side of an appeal.
     *  Reimburses the rest. Creates an appeal if both sides are fully funded.
     *  @param _transactionID The ID of the disputed transaction.
     *  @param _transaction The transaction state.
     *  @param _side The party that pays the appeal fee.
     */
    function fundAppeal(
        uint256 _transactionID,
        Transaction calldata _transaction,
        Party _side
    ) external payable onlyValidTransactionCD(_transactionID, _transaction) {
        require(_transaction.status == Status.DisputeCreated, "No dispute to appeal");

        (uint256 appealPeriodStart, uint256 appealPeriodEnd) = arbitrator.appealPeriod(
            _transaction.disputeID
        );
        require(
            block.timestamp >= appealPeriodStart && block.timestamp < appealPeriodEnd,
            "Funding must be made within the appeal period."
        );

        uint256 multiplier;
        uint256 winner = arbitrator.currentRuling(_transaction.disputeID);
        if (winner == uint256(_side)) {
            multiplier = winnerStakeMultiplier;
        } else if (winner == 0) {
            multiplier = sharedStakeMultiplier;
        } else {
            require(
                block.timestamp < (appealPeriodEnd + appealPeriodStart) / 2,
                "The loser must pay during the first half of the appeal period."
            );
            multiplier = loserStakeMultiplier;
        }

        Round storage round = roundsByTransactionID[_transactionID][
            roundsByTransactionID[_transactionID].length - 1
        ];
        require(!round.hasPaid[uint256(_side)], "Appeal fee is already paid.");

        uint256 appealCost = arbitrator.appealCost(_transaction.disputeID, arbitratorExtraData);
        uint256 totalCost = appealCost.addCap((appealCost.mulCap(multiplier)) / MULTIPLIER_DIVISOR);

        // Take up to the amount necessary to fund the current round at the current costs.
        uint256 contribution; // Amount contributed.
        uint256 remainingETH; // Remaining ETH to send back.
        (contribution, remainingETH) = calculateContribution(
            msg.value,
            totalCost.subCap(round.paidFees[uint256(_side)])
        );
        round.contributions[msg.sender][uint256(_side)] += contribution;
        round.paidFees[uint256(_side)] += contribution;

        emit AppealContribution(_transactionID, _side, msg.sender, contribution);

        if (round.paidFees[uint256(_side)] >= totalCost) {
            round.feeRewards += round.paidFees[uint256(_side)];
            round.fundedSides.push(uint256(_side));
            round.hasPaid[uint256(_side)] = true;
            emit HasPaidAppealFee(_transactionID, _side);
        }

        if (round.fundedSides.length > 1) {
            // At least two sides are fully funded.
            roundsByTransactionID[_transactionID].push();
            round.feeRewards = round.feeRewards.subCap(appealCost);
            arbitrator.appeal{ value: appealCost }(_transaction.disputeID, arbitratorExtraData);
        }

        // Reimburse leftover ETH if any.
        // Deliberate use of send in order to not block the contract in case of reverting fallback.
        if (remainingETH > 0) payable(msg.sender).send(remainingETH);
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
        returns (uint256 taken, uint256 remainder)
    {
        // Take whatever is available, return 0 as leftover ETH.
        if (_requiredAmount > _available) return (_available, 0);

        remainder = _available - _requiredAmount;
        return (_requiredAmount, remainder);
    }

    /** @dev Updates contributions of appeal rounds which are going to be withdrawn.
     *  Caller functions MUST:
     *  (1) check that the transaction is valid and Resolved
     *  (2) send the rewards to the _beneficiary.
     *  @param _beneficiary The address that made contributions.
     *  @param _transactionID The ID of the associated transaction.
     *  @param _round The round from which to withdraw.
     *  @param _finalRuling The final ruling of this transaction.
     *  @param _side Side from which to withdraw.
     *  @return reward The amount of wei available to withdraw from _round.
     */
    function _withdrawFeesAndRewards(
        address _beneficiary,
        uint256 _transactionID,
        uint256 _round,
        uint256 _finalRuling,
        uint256 _side
    ) internal returns (uint256 reward) {
        Round storage round = roundsByTransactionID[_transactionID][_round];

        // Allow to reimburse if funding of the round was unsuccessful.
        if (!round.hasPaid[_side]) {
            reward = round.contributions[_beneficiary][_side];
        } else if (!round.hasPaid[_finalRuling]) {
            // When the ultimate winner didn't fully pay appeal fees, proportionally reimburse unspent fees of the fully funded sides.
            // Note that if only one side is funded it will become a winner and this part of the condition won't be reached.
            reward = round.fundedSides.length > 1
                ? (round.contributions[_beneficiary][_side] * round.feeRewards) /
                    (round.paidFees[round.fundedSides[0]] + round.paidFees[round.fundedSides[1]])
                : 0;
        } else if (_finalRuling == _side) {
            uint256 paidFees = round.paidFees[_side];
            // Reward the winner.
            reward = paidFees > 0 ? (round.contributions[_beneficiary][_side] * round.feeRewards) / paidFees : 0;
        }

        if (reward != 0) {
            round.contributions[_beneficiary][_side] = 0;
        }
    }

    /** @dev Calculate the amount to be paid according to feeRecipientBasisPoint for a particular amount.
     *  @param _amount Amount to pay.
     */
    function calculateFeeRecipientAmount(uint256 _amount) internal view returns(uint256 feeAmount){
        feeAmount = (_amount.mulCap(feeRecipientData.feeRecipientBasisPoint)) / MULTIPLIER_DIVISOR;
    }

    /** @dev Withdraws contributions of appeal rounds. Reimburses contributions
     *  if the appeal was not fully funded.
     *  If the appeal was fully funded, sends the fee stake rewards and reimbursements
     *  proportional to the contributions made to the winner of a dispute.
     *  @param _beneficiary The address that made contributions.
     *  @param _transactionID The ID of the associated transaction.
     *  @param _transaction The transaction state.
     *  @param _round The round from which to withdraw.
     *  @param _side Side from which to withdraw.
     */
    function withdrawFeesAndRewards(
        address payable _beneficiary,
        uint256 _transactionID,
        Transaction calldata _transaction,
        uint256 _round,
        Party _side
    ) external onlyValidTransactionCD(_transactionID, _transaction) {
        require(_transaction.status == Status.Resolved, "The transaction must be resolved.");
        TransactionDispute storage transactionDispute = disputeIDtoTransactionDispute[
            _transaction.disputeID
        ];
        require(transactionDispute.transactionID == _transactionID, "Undisputed transaction");

        uint256 reward = _withdrawFeesAndRewards(
            _beneficiary,
            _transactionID,
            _round,
            uint256(transactionDispute.ruling),
            uint256(_side)
        );
        _beneficiary.send(reward); // It is the user responsibility to accept ETH.
    }

    /** @dev Withdraws contributions of multiple appeal rounds at once.
     *  This function is O(n) where n is the number of rounds.
     *  This could exceed the gas limit, therefore this function should be used
     *  only as a utility and not be relied upon by other contracts.
     *  @param _beneficiary The address that made contributions.
     *  @param _transactionID The ID of the associated transaction.
     *  @param _transaction The transaction state.
     *  @param _cursor The round from where to start withdrawing.
     *  @param _count The number of rounds to iterate. If set to 0 or a value
     *  larger than the number of rounds, iterates until the last round.
     *  @param _side Side to withdraw from.
     */
    function batchRoundWithdraw(
        address payable _beneficiary,
        uint256 _transactionID,
        Transaction calldata _transaction,
        uint256 _cursor,
        uint256 _count,
        Party _side
    ) external onlyValidTransactionCD(_transactionID, _transaction) {
        require(_transaction.status == Status.Resolved, "The transaction must be resolved.");
        TransactionDispute storage transactionDispute = disputeIDtoTransactionDispute[
            _transaction.disputeID
        ];
        require(transactionDispute.transactionID == _transactionID, "Undisputed transaction");
        uint256 finalRuling = uint256(transactionDispute.ruling);

        uint256 reward;
        uint256 totalRounds = roundsByTransactionID[_transactionID].length;
        for (uint256 i = _cursor; i < totalRounds && (_count == 0 || i < _cursor + _count); i++)
            reward += _withdrawFeesAndRewards(_beneficiary, _transactionID, i, finalRuling, uint256(_side));
        _beneficiary.send(reward); // It is the user responsibility to accept ETH.
    }

    /** @dev Give a ruling for a dispute. Must be called by the arbitrator to
     *  enforce the final ruling. The purpose of this function is to ensure that
     *  the address calling it has the right to rule on the contract.
     *  @param _disputeID ID of the dispute in the Arbitrator contract.
     *  @param _ruling Ruling given by the arbitrator. Note that 0 is reserved
     *  for "Not able/wanting to make a decision".
     */
    function rule(uint256 _disputeID, uint256 _ruling) external override {
        require(msg.sender == address(arbitrator), "The caller must be the arbitrator.");
        require(_ruling <= AMOUNT_OF_CHOICES, "Invalid ruling.");

        TransactionDispute storage transactionDispute = disputeIDtoTransactionDispute[_disputeID];
        require(transactionDispute.transactionID != 0, "Dispute does not exist.");
        require(transactionDispute.hasRuling == false, " Dispute already resolved.");

        Round[] storage rounds = roundsByTransactionID[transactionDispute.transactionID];
        Round storage round = rounds[rounds.length - 1];
        uint256 finalRuling = _ruling;

        // If only one side paid its fees we assume the ruling to be in its favor.
        if (round.fundedSides.length == 1) finalRuling = round.fundedSides[0];

        transactionDispute.ruling = Party(finalRuling);
        transactionDispute.hasRuling = true;
        emit Ruling(arbitrator, _disputeID, finalRuling);
    }

    /** @dev Execute a ruling of a dispute. It reimburses the fee to the winning party.
     *  @param _transactionID The index of the transaction.
     *  @param _transaction The transaction state.
     */
    function executeRuling(uint256 _transactionID, Transaction memory _transaction)
        external
        onlyValidTransaction(_transactionID, _transaction)
    {
        require(_transaction.status == Status.DisputeCreated, "Invalid transaction status.");

        TransactionDispute storage transactionDispute = disputeIDtoTransactionDispute[
            _transaction.disputeID
        ];
        require(transactionDispute.hasRuling, "Arbitrator has not ruled yet.");

        uint256 amount = _transaction.amount;
        uint256 settlementSender = _transaction.settlementSender;
        uint256 settlementReceiver = _transaction.settlementReceiver;
        uint256 senderFee = _transaction.senderFee;
        uint256 receiverFee = _transaction.receiverFee;

        uint256 feeAmount;

        _transaction.amount = 0;
        _transaction.settlementSender = 0;
        _transaction.settlementReceiver = 0;
        _transaction.senderFee = 0;
        _transaction.receiverFee = 0;
        _transaction.status = Status.Resolved;
        transactionHashes[_transactionID - 1] = hashTransactionState(_transaction);

        // Give the arbitration fee back.
        // Note that we use `send` to prevent a party from blocking the execution.
        if (transactionDispute.ruling == Party.Sender) {
            _transaction.sender.send(senderFee);

            // If there was a settlement amount proposed
            // we use that to make the partial payment and refund the rest to sender
            if (settlementSender != 0) {
                feeAmount = calculateFeeRecipientAmount(settlementSender);
                // Tokens should not reenter or allow recipients to refuse the transfer.
                require(
                    _transaction.token.transfer(feeRecipientData.feeRecipient, feeAmount),
                    "The `transfer` function must not fail."
                );
                require(
                    _transaction.token.transfer(_transaction.sender, amount - settlementSender),
                    "The `transfer` function must not fail."
                );
                require(
                    _transaction.token.transfer(_transaction.receiver, settlementSender - feeAmount),
                    "The `transfer` function must not fail."
                );
                emit FeeRecipientPaymentInToken(_transactionID, feeAmount, _transaction.token);
            } else {
                require(
                    _transaction.token.transfer(_transaction.sender, amount),
                    "The `transfer` function must not fail."
                );
            }
        } else if (transactionDispute.ruling == Party.Receiver) {
            _transaction.receiver.send(receiverFee);

            // If there was a settlement amount proposed
            // we use that to make the partial payment and refund the rest to sender
            if (settlementReceiver != 0) {
                feeAmount = calculateFeeRecipientAmount(settlementReceiver);
                // Tokens should not reenter or allow recipients to refuse the transfer.
                require(
                    _transaction.token.transfer(feeRecipientData.feeRecipient, feeAmount),
                    "The `transfer` function must not fail."
                );
                require(
                    _transaction.token.transfer(_transaction.sender, amount - settlementReceiver),
                    "The `transfer` function must not fail."
                );
                require(
                    _transaction.token.transfer(_transaction.receiver, settlementReceiver - feeAmount),
                    "The `transfer` function must not fail."
                );
                emit FeeRecipientPaymentInToken(_transactionID, feeAmount, _transaction.token);
            } else {
                feeAmount = calculateFeeRecipientAmount(amount);
                require(
                    _transaction.token.transfer(feeRecipientData.feeRecipient, feeAmount),
                    "The `transfer` function must not fail."
                );
                require(
                    _transaction.token.transfer(_transaction.receiver, amount - feeAmount),
                    "The `transfer` function must not fail."
                );
                emit FeeRecipientPaymentInToken(_transactionID, feeAmount, _transaction.token);
            }
        } else {
            // `senderFee` and `receiverFee` are equal to the arbitration cost.
            uint256 splitArbitrationFee = senderFee / 2;
            _transaction.receiver.send(splitArbitrationFee);
            _transaction.sender.send(splitArbitrationFee);
            // Tokens should not reenter or allow recipients to refuse the transfer.
            // In the case of an uneven token amount, one basic token unit can be burnt.
            uint256 splitAmount = amount / 2;

            feeAmount = calculateFeeRecipientAmount(splitAmount);
            require(
                _transaction.token.transfer(feeRecipientData.feeRecipient, feeAmount),
                "The `transfer` function must not fail."
            );
            require(
                _transaction.token.transfer(_transaction.receiver, splitAmount - feeAmount),
                "The `transfer` function must not fail."
            );
            require(
                _transaction.token.transfer(_transaction.sender, splitAmount),
                "The `transfer` function must not fail."
            );
            emit FeeRecipientPaymentInToken(_transactionID, feeAmount, _transaction.token);
        }

        emit TransactionStateUpdated(_transactionID, _transaction);
        emit TransactionResolved(_transactionID, Resolution.RulingEnforced);
    }

    // **************************** //
    // *     Constant getters     * //
    // **************************** //

    /** @dev Returns the sum of withdrawable wei from appeal rounds.
     *  This function is O(n), where n is the number of rounds of the transaction.
     *  This could exceed the gas limit, therefore this function should only
     *  be used for interface display and not by other contracts.
     *  @param _transactionID The index of the transaction.
     *  @param _transaction The transaction state.
     *  @param _beneficiary The contributor for which to query.
     *  @param _side The side to query.
     *  @return total The total amount of wei available to withdraw.
     */
    function amountWithdrawable(
        uint256 _transactionID,
        Transaction calldata _transaction,
        address _beneficiary,
        Party _side
    ) external view onlyValidTransactionCD(_transactionID, _transaction) returns (uint256 total) {
        if (_transaction.status != Status.Resolved) return total;

        TransactionDispute storage transactionDispute = disputeIDtoTransactionDispute[
            _transaction.disputeID
        ];

        if (transactionDispute.transactionID != _transactionID) return total;
        uint256 finalRuling = uint256(transactionDispute.ruling);

        Round[] storage rounds = roundsByTransactionID[_transactionID];
        uint256 totalRounds = rounds.length;
        for (uint256 i = 0; i < totalRounds; i++) {
            Round storage round = rounds[i];

            if (!round.hasPaid[uint256(_side)]) {
                total += round.contributions[_beneficiary][uint256(_side)];
            } else if (!round.hasPaid[finalRuling]) {
                // When the ultimate winner didn't fully pay appeal fees, proportionally reimburse unspent fees of the fully funded sides.
                // Note that if only one side is funded it will become a winner and this part of the condition won't be reached.
                total += round.fundedSides.length > 1
                ? (round.contributions[_beneficiary][uint256(_side)] * round.feeRewards) /
                    (round.paidFees[round.fundedSides[0]] + round.paidFees[round.fundedSides[1]])
                : 0;
            } else if (finalRuling == uint256(_side)) {
                uint256 paidFees = round.paidFees[uint256(_side)];
                // Reward the winner.
                total += paidFees > 0 ? (round.contributions[_beneficiary][uint256(_side)] * round.feeRewards) / paidFees : 0;
            }
        }
    }

    /** @dev Getter to know the count of transactions.
     *  @return The count of transactions.
     */
    function getCountTransactions() external view returns (uint256) {
        return transactionHashes.length;
    }

    /** @dev Gets the number of rounds of the specific transaction.
     *  @param _transactionID The ID of the transaction.
     *  @return The number of rounds.
     */
    function getNumberOfRounds(uint256 _transactionID) external view returns (uint256) {
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
    ) external view returns (uint256[3] memory contributions) {
        Round storage round = roundsByTransactionID[_transactionID][_round];
        contributions = round.contributions[_contributor];
    }

    /** @dev Gets the information on a round of a transaction.
     *  @param _transactionID The ID of the transaction.
     *  @param _round The round to query.
     *  @return paidFees
     *          hasPaid
     *          feeRewards
     *          fundedSides
     *          appealed
     */
    function getRoundInfo(uint256 _transactionID, uint256 _round)
        external
        view
        returns (
            uint256[3] memory paidFees,
            bool[3] memory hasPaid,
            uint256 feeRewards,
            uint256[] memory fundedSides,
            bool appealed
        )
    {
        Round storage round = roundsByTransactionID[_transactionID][_round];
        return (
            round.paidFees,
            round.hasPaid,
            round.feeRewards,
            round.fundedSides,
            _round != roundsByTransactionID[_transactionID].length - 1
        );
    }

    /**
     * @dev Gets the hashed version of the transaction state.
     * If the caller function is using a Transaction object stored in calldata,
     * this function is unnecessarily expensive, use hashTransactionStateCD instead.
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
                    _transaction.settlementSender,
                    _transaction.settlementReceiver,
                    _transaction.token,
                    _transaction.deadline,
                    _transaction.disputeID,
                    _transaction.senderFee,
                    _transaction.receiverFee,
                    _transaction.lastInteraction,
                    _transaction.status
                )
            );
    }

    /**
     * @dev Gets the hashed version of the transaction state.
     * This function is cheap and can only be used when the caller function is
     * using a Transaction object stored in calldata.
     * @param _transaction The transaction state.
     * @return The hash of the transaction state.
     */
    function hashTransactionStateCD(Transaction calldata _transaction)
        public
        pure
        returns (bytes32)
    {
        return
            keccak256(
                abi.encodePacked(
                    _transaction.sender,
                    _transaction.receiver,
                    _transaction.amount,
                    _transaction.settlementSender,
                    _transaction.settlementReceiver,
                    _transaction.token,
                    _transaction.deadline,
                    _transaction.disputeID,
                    _transaction.senderFee,
                    _transaction.receiverFee,
                    _transaction.lastInteraction,
                    _transaction.status
                )
            );
    }
}
