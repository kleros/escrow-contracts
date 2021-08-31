const TransactionStatus = {
  NoDispute: 0,
  WaitingSettlementSender: 1,
  WaitingSettlementReceiver: 2,
  WaitingSender: 3,
  WaitingReceiver: 4,
  DisputeCreated: 5,
  Resolved: 6,
};

module.exports = TransactionStatus;
