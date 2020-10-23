const { ethers } = require('@nomiclabs/buidler')
const { readArtifact } = require('@nomiclabs/buidler/plugins')
const { solidity } = require('ethereum-waffle')
const { use, expect } = require('chai')
const {
  randomInt,
  getEmittedEvent,
  latestTime,
  increaseTime
} = require('../src/test-helpers')
const TransactionStatus = require('../src/entities/TransactionStatus')
const TransactionParty = require('../src/entities/TransactionParty')
const DisputeRuling = require('../src/entities/DisputeRuling')

use(solidity)

const { BigNumber } = ethers

describe('MultipleArbitrableTransactionWithAppeals contract', async () => {
  const arbitrationFee = 20
  const arbitratorExtraData = '0x85'
  const appealTimeout = 100
  const feeTimeout = 100
  const timeoutPayment = 100
  const amount = 1000
  const sharedMultiplier = 5000
  const winnerMultiplier = 2000
  const loserMultiplier = 8000
  const NON_PAYABLE_VALUE = BigNumber.from((2n ** 256n - 2n) / 2n)
  const metaEvidenceUri = 'https://kleros.io'

  let arbitrator
  let governor
  let sender
  let receiver
  let other
  let crowdfunder1
  let crowdfunder2

  let contract
  let MULTIPLIER_DIVISOR
  let currentTime

  beforeEach('Setup contracts', async () => {
    ;[
      governor,
      sender,
      receiver,
      other,
      crowdfunder1,
      crowdfunder2
    ] = await ethers.getSigners()
    senderAddress = await sender.getAddress()
    receiverAddress = await receiver.getAddress()

    const arbitratorArtifact = await readArtifact(
      './artifacts/0.4.x',
      'EnhancedAppealableArbitrator'
    )
    const Arbitrator = await ethers.getContractFactory(
      arbitratorArtifact.abi,
      arbitratorArtifact.bytecode
    )
    arbitrator = await Arbitrator.deploy(
      String(arbitrationFee),
      ethers.constants.AddressZero,
      arbitratorExtraData,
      appealTimeout
    )
    await arbitrator.deployed()
    // Make appeals go to the same arbitrator
    await arbitrator.changeArbitrator(arbitrator.address)

    const contractArtifact = await readArtifact(
      './artifacts/0.7.x',
      'MultipleArbitrableTransactionWithAppeals'
    )
    const MultipleArbitrableTransaction = await ethers.getContractFactory(
      contractArtifact.abi,
      contractArtifact.bytecode
    )
    contract = await MultipleArbitrableTransaction.deploy(
      arbitrator.address,
      arbitratorExtraData,
      feeTimeout,
      sharedMultiplier,
      winnerMultiplier,
      loserMultiplier
    )
    await contract.deployed()

    MULTIPLIER_DIVISOR = await contract.MULTIPLIER_DIVISOR()
    currentTime = await latestTime()
  })

  describe('Initialization', () => {
    it('Should set the correct values in constructor', async () => {
      expect(await contract.arbitrator()).to.equal(
        arbitrator.address,
        'Arbitrator address not properly set'
      )
      expect(await contract.arbitratorExtraData()).to.equal(
        arbitratorExtraData,
        'Arbitrator extra data not properly set'
      )
      expect(await contract.feeTimeout()).to.equal(
        feeTimeout,
        'Fee timeout not properly set'
      )
      expect(await contract.sharedStakeMultiplier()).to.equal(
        sharedMultiplier,
        'Shared multiplier not properly set'
      )
      expect(await contract.winnerStakeMultiplier()).to.equal(
        winnerMultiplier,
        'Winner multiplier not properly set'
      )
      expect(await contract.loserStakeMultiplier()).to.equal(
        loserMultiplier,
        'Loser multiplier not properly set'
      )
    })
  })

  describe('Create new transaction', () => {
    it('Should create a transaction when parameters are valid', async () => {
      const metaEvidence = metaEvidenceUri

      const txPromise = contract
        .connect(sender)
        .createTransaction(timeoutPayment, receiverAddress, metaEvidence, {
          value: amount
        })
      const transactionCount = await contract
        .connect(receiver)
        .getCountTransactions()
      const expectedTransactionID = 1
      const contractBalance = await web3.eth.getBalance(contract.address)

      expect(transactionCount).to.equal(
        BigNumber.from(expectedTransactionID),
        'Invalid transactionCount'
      )
      await expect(txPromise)
        .to.emit(contract, 'TransactionCreated')
        .withArgs(expectedTransactionID, senderAddress, receiverAddress, amount)
      await expect(txPromise)
        .to.emit(contract, 'MetaEvidence')
        .withArgs(expectedTransactionID, metaEvidence)
      expect(contractBalance).to.equal(
        BigNumber.from(amount),
        'Invalid contract balance'
      )
    })

    it('Should emit a correct TransactionStateUpdated event for the newly created transaction', async () => {
      currentTime = await latestTime()
      const [
        receipt,
        transactionId,
        transaction
      ] = await createTransactionHelper(amount)

      expect(transactionId).to.equal(1, 'Invalid transaction ID')
      expect(transaction.status).to.equal(
        TransactionStatus.NoDispute,
        'Invalid status'
      )
      expect(transaction.sender).to.equal(
        senderAddress,
        'Invalid sender address'
      )
      expect(transaction.receiver).to.equal(
        receiverAddress,
        'Invalid receiver address'
      )
      expect(Number(transaction.lastInteraction)).to.be.closeTo(
        currentTime,
        10,
        'Invalid last interaction'
      )
      expect(transaction.amount).to.equal(amount, 'Invalid transaction amount')
      expect(transaction.timeoutPayment).to.equal(
        timeoutPayment,
        'Wrong timeoutPayment'
      )
      expect(transaction.disputeID).to.equal(0, 'Invalid dispute ID')
      expect(transaction.senderFee).to.equal(0, 'Invalid senderFee')
      expect(transaction.receiverFee).to.equal(0, 'Invalid receieverFee')
      expect(transaction.ruling).to.equal(0, 'Invalid ruling')
    })

    it('Should store the proper hashed transaction state of the newly created transaction', async () => {
      const [
        receipt,
        transactionId,
        transaction
      ] = await createTransactionHelper(amount)

      // transactions IDs start at 1, so index in transactionHashes will be transactionId - 1.
      const actualHash = await contract.transactionHashes(transactionId - 1)
      const expectedHash = await contract.hashTransactionState(transaction)
      const expectedHashCD = await contract.hashTransactionStateCD(transaction)

      expect(actualHash).to.equal(
        expectedHash,
        'Invalid transaction state hash'
      )
      expect(actualHash).to.equal(
        expectedHashCD,
        'Invalid transaction state hash when using calldata argument'
      )
    })
  })

  describe('Reimburse sender', () => {
    it('Should reimburse the sender and update the hash correctly', async () => {
      const [
        receipt,
        transactionId,
        transaction
      ] = await createTransactionHelper(amount)

      const balancesBefore = await getBalances()
      const reimburseTx = await contract
        .connect(receiver)
        .reimburse(transactionId, transaction, amount)
      const reimburseReceipt = await reimburseTx.wait()
      const [rTransactionId, rTransaction] = getEmittedEvent(
        'TransactionStateUpdated',
        reimburseReceipt
      ).args
      const balancesAfter = await getBalances()

      expect(balancesBefore.sender.add(BigNumber.from(amount))).to.equal(
        balancesAfter.sender,
        'Sender was not reimburse correctly'
      )

      const updatedHash = await contract.transactionHashes(transactionId - 1)
      const expectedHash = await contract.hashTransactionState(rTransaction)
      expect(updatedHash).to.equal(
        expectedHash,
        'Hash was not updated correctly'
      )
    })

    it('Should emit correct TransactionStateUpdated and Payment events', async () => {
      const [
        receipt,
        transactionId,
        transaction
      ] = await createTransactionHelper(amount)

      currentTime = await latestTime()
      const reimburseTx = await contract
        .connect(receiver)
        .reimburse(transactionId, transaction, amount)
      const reimburseReceipt = await reimburseTx.wait()
      const [rTransactionId, rTransaction] = getEmittedEvent(
        'TransactionStateUpdated',
        reimburseReceipt
      ).args
      const [
        pTransactionId,
        amountReimbursed,
        reimburseCaller
      ] = getEmittedEvent('Payment', reimburseReceipt).args

      expect(rTransactionId).to.equal(transactionId, 'Invalid transaction ID')
      expect(rTransaction.status).to.equal(transaction.status, 'Invalid status')
      expect(rTransaction.sender).to.equal(
        senderAddress,
        'Invalid sender address'
      )
      expect(rTransaction.receiver).to.equal(
        receiverAddress,
        'Invalid receiver address'
      )
      expect(Number(rTransaction.lastInteraction)).to.be.closeTo(
        currentTime,
        10,
        'Invalid last interaction'
      )
      expect(rTransaction.amount).to.equal(0, 'Invalid transaction amount')
      expect(rTransaction.timeoutPayment).to.equal(
        transaction.timeoutPayment,
        'Wrong timeoutPayment'
      )
      expect(rTransaction.disputeID).to.equal(0, 'Invalid dispute ID')
      expect(rTransaction.senderFee).to.equal(0, 'Invalid senderFee')
      expect(rTransaction.receiverFee).to.equal(0, 'Invalid receieverFee')
      expect(rTransaction.ruling).to.equal(0, 'Invalid ruling')

      expect(pTransactionId).to.equal(
        transactionId,
        'Invalid transaction ID on Payment event'
      )
      expect(amountReimbursed).to.equal(
        amount,
        'Invalid amount reimbursed on Payment event'
      )
      expect(reimburseCaller).to.equal(
        receiverAddress,
        'Invalid caller address on Payment event'
      )
    })

    it('Should revert on bad inputs', async () => {
      const [
        receipt,
        transactionId,
        transaction
      ] = await createTransactionHelper(amount)

      await expect(
        contract.connect(sender).reimburse(transactionId, transaction, amount)
      ).to.be.revertedWith('The caller must be the receiver.')
      await expect(
        contract
          .connect(receiver)
          .reimburse(transactionId, transaction, amount * 2)
      ).to.be.revertedWith('Maximum reimbursement available exceeded.')

      // Reimburse half of the total amount
      currentTime = await latestTime()
      const reimburseTx = await contract
        .connect(receiver)
        .reimburse(transactionId, transaction, 500)
      const reimburseReceipt = await reimburseTx.wait()
      const [rTransactionId, rTransaction] = getEmittedEvent(
        'TransactionStateUpdated',
        reimburseReceipt
      ).args

      await expect(
        contract.connect(receiver).reimburse(transactionId, transaction, amount)
      ).to.be.revertedWith("Transaction doesn't match stored hash")
      await expect(
        contract
          .connect(receiver)
          .reimburse(rTransactionId, rTransaction, amount)
      ).to.be.revertedWith('Maximum reimbursement available exceeded.')
    })
  })

  describe('Pay receiver', () => {
    it('Should pay the receiver and update the hash correctly', async () => {
      const [
        receipt,
        transactionId,
        transaction
      ] = await createTransactionHelper(amount)

      const balancesBefore = await getBalances()
      const payTx = await contract
        .connect(sender)
        .pay(transactionId, transaction, amount)
      const payReceipt = await payTx.wait()
      const [payTransactionId, payTransaction] = getEmittedEvent(
        'TransactionStateUpdated',
        payReceipt
      ).args
      const balancesAfter = await getBalances()

      expect(balancesBefore.receiver.add(BigNumber.from(amount))).to.equal(
        balancesAfter.receiver,
        'Receiver was not paid correctly'
      )

      const updatedHash = await contract.transactionHashes(transactionId - 1)
      const expectedHash = await contract.hashTransactionState(payTransaction)
      expect(updatedHash).to.equal(
        expectedHash,
        'Hash was not updated correctly'
      )
    })

    it('Should emit correct TransactionStateUpdated and Payment events', async () => {
      const [
        receipt,
        transactionId,
        transaction
      ] = await createTransactionHelper(amount)

      currentTime = await latestTime()
      const payTx = await contract
        .connect(sender)
        .pay(transactionId, transaction, amount)
      const payReceipt = await payTx.wait()
      const [payTransactionId, payTransaction] = getEmittedEvent(
        'TransactionStateUpdated',
        payReceipt
      ).args
      const [pTransactionId, amountPaid, payCaller] = getEmittedEvent(
        'Payment',
        payReceipt
      ).args

      expect(payTransactionId).to.equal(transactionId, 'Invalid transaction ID')
      expect(payTransaction.status).to.equal(
        transaction.status,
        'Invalid status'
      )
      expect(payTransaction.sender).to.equal(
        senderAddress,
        'Invalid sender address'
      )
      expect(payTransaction.receiver).to.equal(
        receiverAddress,
        'Invalid receiver address'
      )
      expect(Number(payTransaction.lastInteraction)).to.be.closeTo(
        currentTime,
        10,
        'Invalid last interaction'
      )
      expect(payTransaction.amount).to.equal(0, 'Invalid transaction amount')
      expect(payTransaction.timeoutPayment).to.equal(
        transaction.timeoutPayment,
        'Wrong timeoutPayment'
      )
      expect(payTransaction.disputeID).to.equal(0, 'Invalid dispute ID')
      expect(payTransaction.senderFee).to.equal(0, 'Invalid senderFee')
      expect(payTransaction.receiverFee).to.equal(0, 'Invalid receieverFee')
      expect(payTransaction.ruling).to.equal(0, 'Invalid ruling')

      expect(pTransactionId).to.equal(
        transactionId,
        'Invalid transaction ID on Payment event'
      )
      expect(amountPaid).to.equal(
        amount,
        'Invalid amount reimbursed on Payment event'
      )
      expect(payCaller).to.equal(
        senderAddress,
        'Invalid caller address on Payment event'
      )
    })

    it('Should revert on bad inputs', async () => {
      const [
        receipt,
        transactionId,
        transaction
      ] = await createTransactionHelper(amount)

      await expect(
        contract.connect(receiver).pay(transactionId, transaction, amount)
      ).to.be.revertedWith('The caller must be the sender.')
      await expect(
        contract.connect(sender).pay(transactionId, transaction, amount * 2)
      ).to.be.revertedWith('Maximum amount available for payment exceeded.')

      // Reimburse half of the total amount
      currentTime = await latestTime()
      const payTx = await contract
        .connect(sender)
        .pay(transactionId, transaction, 500)
      const payReceipt = await payTx.wait()
      const [payTransactionId, payTransaction] = getEmittedEvent(
        'TransactionStateUpdated',
        payReceipt
      ).args

      await expect(
        contract.connect(sender).pay(transactionId, transaction, amount)
      ).to.be.revertedWith("Transaction doesn't match stored hash")
      await expect(
        contract.connect(sender).pay(payTransactionId, payTransaction, amount)
      ).to.be.revertedWith('Maximum amount available for payment exceeded.')
    })
  })

  describe('Execute Transaction', () => {
    it('Should execute transaction and update the hash correctly', async () => {
      const [
        receipt,
        transactionId,
        transaction
      ] = await createTransactionHelper(amount)

      await increaseTime(timeoutPayment)

      const balancesBefore = await getBalances()
      // Anyone should be allowed to execute the transaction.
      const executeTx = await contract
        .connect(other)
        .executeTransaction(transactionId, transaction)
      const executeReceipt = await executeTx.wait()
      const [executeTransactionId, executeTransaction] = getEmittedEvent(
        'TransactionStateUpdated',
        executeReceipt
      ).args
      const balancesAfter = await getBalances()

      expect(balancesBefore.receiver.add(BigNumber.from(amount))).to.equal(
        balancesAfter.receiver,
        'Receiver was not paid correctly'
      )

      const updatedHash = await contract.transactionHashes(transactionId - 1)
      const expectedHash = await contract.hashTransactionState(
        executeTransaction
      )
      expect(updatedHash).to.equal(
        expectedHash,
        'Hash was not updated correctly'
      )
    })

    it('Should emit correct TransactionStateUpdated event', async () => {
      const [
        receipt,
        transactionId,
        transaction
      ] = await createTransactionHelper(amount)

      await increaseTime(timeoutPayment)

      currentTime = await latestTime()
      const executeTx = await contract
        .connect(other)
        .executeTransaction(transactionId, transaction)
      const executeReceipt = await executeTx.wait()
      const [executeTransactionId, executeTransaction] = getEmittedEvent(
        'TransactionStateUpdated',
        executeReceipt
      ).args

      expect(executeTransactionId).to.equal(
        transactionId,
        'Invalid transaction ID'
      )
      expect(executeTransaction.status).to.equal(
        TransactionStatus.Resolved,
        'Invalid status'
      )
      expect(executeTransaction.sender).to.equal(
        senderAddress,
        'Invalid sender address'
      )
      expect(executeTransaction.receiver).to.equal(
        receiverAddress,
        'Invalid receiver address'
      )
      expect(executeTransaction.lastInteraction).to.equal(
        transaction.lastInteraction,
        'Invalid last interaction'
      )
      expect(executeTransaction.amount).to.equal(
        0,
        'Invalid transaction amount'
      )
      expect(executeTransaction.timeoutPayment).to.equal(
        transaction.timeoutPayment,
        'Wrong timeoutPayment'
      )
      expect(executeTransaction.disputeID).to.equal(0, 'Invalid dispute ID')
      expect(executeTransaction.senderFee).to.equal(0, 'Invalid senderFee')
      expect(executeTransaction.receiverFee).to.equal(0, 'Invalid receieverFee')
      expect(executeTransaction.ruling).to.equal(0, 'Invalid ruling')
    })

    it('Should revert if timeout has not passed', async () => {
      const [
        receipt,
        transactionId,
        transaction
      ] = await createTransactionHelper(amount)

      await expect(
        contract.connect(other).executeTransaction(transactionId, transaction)
      ).to.be.revertedWith('The timeout has not passed yet.')
    })

    it('Should revert withdraws after execute is called', async () => {
      const [
        receipt,
        transactionId,
        transaction
      ] = await createTransactionHelper(amount)

      await increaseTime(timeoutPayment)

      currentTime = await latestTime()
      const executeTx = await contract
        .connect(other)
        .executeTransaction(transactionId, transaction)
      const executeReceipt = await executeTx.wait()
      const [executeTransactionId, executeTransaction] = getEmittedEvent(
        'TransactionStateUpdated',
        executeReceipt
      ).args

      await expect(
        contract
          .connect(other)
          .executeTransaction(executeTransactionId, executeTransaction)
      ).to.be.revertedWith('The transaction must not be disputed.')
      await expect(
        contract
          .connect(sender)
          .pay(executeTransactionId, executeTransaction, amount)
      ).to.be.revertedWith('The transaction must not be disputed.')
      await expect(
        contract
          .connect(receiver)
          .reimburse(executeTransactionId, executeTransaction, amount)
      ).to.be.revertedWith('The transaction must not be disputed.')
    })
  })

  describe('Disputes', () => {
    it('Should create dispute and execute ruling correctly, making the sender the winner', async () => {
      const [
        receipt,
        transactionId,
        transaction
      ] = await createTransactionHelper(amount)
      const [
        disputeID,
        disputeTransactionId,
        disputeTransaction
      ] = await createDisputeHelper(transactionId, transaction)
      // Rule
      await giveFinalRulingHelper(disputeID, DisputeRuling.Sender)
      // Anyone can execute ruling
      const balancesBefore = await getBalances()
      const [ruleTransactionId, ruleTransaction] = await executeRulingHelper(
        disputeTransactionId,
        disputeTransaction,
        other
      )
      const balancesAfter = await getBalances()

      expect(
        balancesBefore.sender.add(BigNumber.from(amount + arbitrationFee))
      ).to.equal(balancesAfter.sender, 'Sender was not rewarded correctly')
      expect(balancesBefore.receiver).to.equal(
        balancesAfter.receiver,
        'Receiver must not be rewarded'
      )

      const updatedHash = await contract.transactionHashes(transactionId - 1)
      const expectedHash = await contract.hashTransactionState(ruleTransaction)
      expect(updatedHash).to.equal(
        expectedHash,
        'Hash was not updated correctly'
      )
    })

    it('Should create dispute and execute ruling correctly, making the receiver the winner', async () => {
      const [
        receipt,
        transactionId,
        transaction
      ] = await createTransactionHelper(amount)
      const [
        disputeID,
        disputeTransactionId,
        disputeTransaction
      ] = await createDisputeHelper(transactionId, transaction)
      // Rule
      await giveFinalRulingHelper(disputeID, DisputeRuling.Receiver)
      // Anyone can execute ruling
      const balancesBefore = await getBalances()
      const [ruleTransactionId, ruleTransaction] = await executeRulingHelper(
        disputeTransactionId,
        disputeTransaction,
        other
      )
      const balancesAfter = await getBalances()

      expect(
        balancesBefore.receiver.add(BigNumber.from(amount + arbitrationFee))
      ).to.equal(balancesAfter.receiver, 'Receiver was not rewarded correctly')
      expect(balancesBefore.sender).to.equal(
        balancesAfter.sender,
        'Sender must not be rewarded'
      )

      const updatedHash = await contract.transactionHashes(transactionId - 1)
      const expectedHash = await contract.hashTransactionState(ruleTransaction)
      expect(updatedHash).to.equal(
        expectedHash,
        'Hash was not updated correctly'
      )
    })

    it('Should create dispute and execute ruling correctly when jurors refuse to rule', async () => {
      const [
        receipt,
        transactionId,
        transaction
      ] = await createTransactionHelper(amount)
      const [
        disputeID,
        disputeTransactionId,
        disputeTransaction
      ] = await createDisputeHelper(transactionId, transaction)
      // Rule
      await giveFinalRulingHelper(disputeID, DisputeRuling.RefusedToRule)
      // Anyone can execute ruling
      const balancesBefore = await getBalances()
      const [ruleTransactionId, ruleTransaction] = await executeRulingHelper(
        disputeTransactionId,
        disputeTransaction,
        other
      )
      const balancesAfter = await getBalances()

      expect(
        balancesBefore.receiver.add(
          BigNumber.from((amount + arbitrationFee) / 2)
        )
      ).to.equal(balancesAfter.receiver, 'Receiver was not rewarded correctly')
      expect(
        balancesBefore.sender.add(BigNumber.from((amount + arbitrationFee) / 2))
      ).to.equal(balancesAfter.sender, 'Sender was not rewarded correctly')

      const updatedHash = await contract.transactionHashes(transactionId - 1)
      const expectedHash = await contract.hashTransactionState(ruleTransaction)
      expect(updatedHash).to.equal(
        expectedHash,
        'Hash was not updated correctly'
      )
    })

    it('Should update Transaction state correctly when dispute is resolved', async () => {
      const [
        receipt,
        transactionId,
        transaction
      ] = await createTransactionHelper(amount)
      currentTime = await latestTime()
      const [
        disputeID,
        disputeTransactionId,
        disputeTransaction
      ] = await createDisputeHelper(transactionId, transaction)
      // Rule
      await giveFinalRulingHelper(disputeID, DisputeRuling.Sender)
      // Anyone can execute ruling
      const [ruleTransactionId, ruleTransaction] = await executeRulingHelper(
        disputeTransactionId,
        disputeTransaction,
        other
      )

      expect(ruleTransactionId).to.equal(
        transactionId,
        'Invalid transaction ID'
      )
      expect(ruleTransaction.status).to.equal(
        TransactionStatus.Resolved,
        'Invalid status'
      )
      expect(ruleTransaction.sender).to.equal(
        senderAddress,
        'Invalid sender address'
      )
      expect(ruleTransaction.receiver).to.equal(
        receiverAddress,
        'Invalid receiver address'
      )
      expect(Number(ruleTransaction.lastInteraction)).to.be.closeTo(
        currentTime,
        10,
        'Invalid last interaction'
      )
      expect(ruleTransaction.amount).to.equal(0, 'Invalid transaction amount')
      expect(ruleTransaction.timeoutPayment).to.equal(
        timeoutPayment,
        'Wrong timeoutPayment'
      )
      expect(ruleTransaction.disputeID).to.equal(
        disputeID,
        'Invalid dispute ID'
      )
      expect(ruleTransaction.senderFee).to.equal(0, 'Invalid senderFee')
      expect(ruleTransaction.receiverFee).to.equal(0, 'Invalid receieverFee')
      expect(ruleTransaction.ruling).to.equal(
        DisputeRuling.Sender,
        'Invalid ruling'
      )

      const updatedHash = await contract.transactionHashes(transactionId - 1)
      const expectedHash = await contract.hashTransactionState(ruleTransaction)
      expect(updatedHash).to.equal(
        expectedHash,
        'Hash was not updated correctly'
      )
    })

    it('Should refund overpaid arbitration fees', async () => {
      const [
        receipt,
        transactionId,
        transaction
      ] = await createTransactionHelper(amount)
      const gasPrice = 1000000000

      const balancesBefore = await getBalances()
      // Sender overpays fees
      const senderFeePromise = contract
        .connect(sender)
        .payArbitrationFeeBySender(transactionId, transaction, {
          value: arbitrationFee + 100,
          gasPrice: gasPrice
        })
      const senderFeeTx = await senderFeePromise
      const senderFeeReceipt = await senderFeeTx.wait()
      expect(senderFeePromise)
        .to.emit(contract, 'HasToPayFee')
        .withArgs(transactionId, TransactionParty.Receiver)
      const [senderFeeTransactionId, senderFeeTransaction] = getEmittedEvent(
        'TransactionStateUpdated',
        senderFeeReceipt
      ).args

      // Receiver overpays fees, dispute gets created and both parties get refunded
      const receiverFeePromise = contract
        .connect(receiver)
        .payArbitrationFeeByReceiver(
          senderFeeTransactionId,
          senderFeeTransaction,
          {
            value: arbitrationFee + 100,
            gasPrice: gasPrice
          }
        )
      const receiverFeeTx = await receiverFeePromise
      const receiverFeeReceipt = await receiverFeeTx.wait()
      const [
        receiverFeeTransactionId,
        receiverFeeTransaction
      ] = getEmittedEvent('TransactionStateUpdated', receiverFeeReceipt).args
      expect(receiverFeePromise)
        .to.emit(contract, 'Dispute')
        .withArgs(
          arbitrator.address,
          receiverFeeTransaction.disputeID,
          receiverFeeTransactionId,
          receiverFeeTransactionId
        )

      const balancesAfter = await getBalances()

      expect(balancesBefore.sender).to.equal(
        balancesAfter.sender
          .add(BigNumber.from(arbitrationFee))
          .add(senderFeeReceipt.gasUsed * gasPrice),
        'Sender was not refunded correctly'
      )
      expect(balancesBefore.receiver).to.equal(
        balancesAfter.receiver
          .add(BigNumber.from(arbitrationFee))
          .add(receiverFeeReceipt.gasUsed * gasPrice),
        'Receiver was not refunded correctly'
      )

      expect(receiverFeeTransaction.senderFee).to.equal(
        BigNumber.from(arbitrationFee),
        'Invalid senderFee'
      )
      expect(receiverFeeTransaction.receiverFee).to.equal(
        BigNumber.from(arbitrationFee),
        'Invalid receieverFee'
      )
    })

    it('Should reimburse the sender in case of timeout of the receiver', async () => {
      const [
        receipt,
        transactionId,
        transaction
      ] = await createTransactionHelper(amount)

      // Sender pays fees
      const senderFeePromise = contract
        .connect(sender)
        .payArbitrationFeeBySender(transactionId, transaction, {
          value: arbitrationFee
        })
      const senderFeeTx = await senderFeePromise
      const senderFeeReceipt = await senderFeeTx.wait()
      expect(senderFeePromise)
        .to.emit(contract, 'HasToPayFee')
        .withArgs(transactionId, TransactionParty.Receiver)
      const [senderFeeTransactionId, senderFeeTransaction] = getEmittedEvent(
        'TransactionStateUpdated',
        senderFeeReceipt
      ).args

      // feeTimeout for receiver passes and sender gets to claim amount and his fee.
      await increaseTime(feeTimeout + 1)
      const balancesBefore = await getBalances()
      // Anyone can execute the timeout
      const timeoutTx = await contract
        .connect(other)
        .timeOutBySender(senderFeeTransactionId, senderFeeTransaction)
      const timeoutReceipt = await timeoutTx.wait()
      const [timeoutTransactionId, timeoutTransaction] = getEmittedEvent(
        'TransactionStateUpdated',
        timeoutReceipt
      ).args
      const balancesAfter = await getBalances()

      expect(
        balancesBefore.sender.add(BigNumber.from(amount + arbitrationFee))
      ).to.equal(balancesAfter.sender, 'Sender was not reimbursed correctly')
      // Receiver must not be paid anything
      expect(balancesBefore.receiver).to.equal(
        balancesAfter.receiver,
        'Wrong receiver balance.'
      )

      // Receiver must not be allowed to pay his fees afterwards
      await expect(
        contract
          .connect(receiver)
          .payArbitrationFeeByReceiver(
            timeoutTransactionId,
            timeoutTransaction,
            { value: arbitrationFee }
          )
      ).to.be.revertedWith(
        'Dispute has already been created or because the transaction has been executed.'
      )
    })

    it('Should pay the receiver in case of timeout of the sender', async () => {
      const [
        receipt,
        transactionId,
        transaction
      ] = await createTransactionHelper(amount)

      // Receiver pays fee
      const receiverFeePromise = contract
        .connect(receiver)
        .payArbitrationFeeByReceiver(transactionId, transaction, {
          value: arbitrationFee
        })
      const receiverFeeTx = await receiverFeePromise
      const receiverFeeReceipt = await receiverFeeTx.wait()
      expect(receiverFeePromise)
        .to.emit(contract, 'HasToPayFee')
        .withArgs(transactionId, TransactionParty.Sender)
      const [
        receiverFeeTransactionId,
        receiverFeeTransaction
      ] = getEmittedEvent('TransactionStateUpdated', receiverFeeReceipt).args

      // feeTimeout for sender passes and sender gets to claim amount and his fee.
      await increaseTime(feeTimeout + 1)
      const balancesBefore = await getBalances()
      // Anyone can execute the timeout
      const timeoutTx = await contract
        .connect(other)
        .timeOutByReceiver(receiverFeeTransactionId, receiverFeeTransaction)
      const timeoutReceipt = await timeoutTx.wait()
      const [timeoutTransactionId, timeoutTransaction] = getEmittedEvent(
        'TransactionStateUpdated',
        timeoutReceipt
      ).args
      const balancesAfter = await getBalances()

      expect(
        balancesBefore.receiver.add(BigNumber.from(amount + arbitrationFee))
      ).to.equal(balancesAfter.receiver, 'Receiver was not paid correctly')
      // Sender must not be paid anything
      expect(balancesBefore.sender).to.equal(
        balancesAfter.sender,
        'Wrong sender balance.'
      )

      // Sender must not be allowed to pay his fees afterwards
      await expect(
        contract
          .connect(sender)
          .payArbitrationFeeBySender(timeoutTransactionId, timeoutTransaction, {
            value: arbitrationFee
          })
      ).to.be.revertedWith(
        'Dispute has already been created or because the transaction has been executed.'
      )
    })

    it("Shouldn't be allowed to execute the timeout before it's right (Sender)", async () => {
      const [
        receipt,
        transactionId,
        transaction
      ] = await createTransactionHelper(amount)

      await expect(
        contract.connect(other).timeOutBySender(transactionId, transaction)
      ).to.be.revertedWith('The transaction is not waiting on the receiver.')
      await expect(
        contract.connect(other).timeOutByReceiver(transactionId, transaction)
      ).to.be.revertedWith('The transaction is not waiting on the sender.')

      // Sender pays fees
      const senderFeePromise = contract
        .connect(sender)
        .payArbitrationFeeBySender(transactionId, transaction, {
          value: arbitrationFee
        })
      const senderFeeTx = await senderFeePromise
      const senderFeeReceipt = await senderFeeTx.wait()
      expect(senderFeePromise)
        .to.emit(contract, 'HasToPayFee')
        .withArgs(transactionId, TransactionParty.Receiver)
      const [senderFeeTransactionId, senderFeeTransaction] = getEmittedEvent(
        'TransactionStateUpdated',
        senderFeeReceipt
      ).args

      await increaseTime(feeTimeout / 2)
      await expect(
        contract
          .connect(other)
          .timeOutBySender(senderFeeTransactionId, senderFeeTransaction)
      ).to.be.revertedWith('Timeout time has not passed yet.')
    })

    it("Shouldn't be allowed to execute the timeout before it's right (Receiver)", async () => {
      const [
        receipt,
        transactionId,
        transaction
      ] = await createTransactionHelper(amount)

      await expect(
        contract.connect(other).timeOutBySender(transactionId, transaction)
      ).to.be.revertedWith('The transaction is not waiting on the receiver.')
      await expect(
        contract.connect(other).timeOutByReceiver(transactionId, transaction)
      ).to.be.revertedWith('The transaction is not waiting on the sender.')

      // Receiver pays fees
      const receiverFeePromise = contract
        .connect(receiver)
        .payArbitrationFeeByReceiver(transactionId, transaction, {
          value: arbitrationFee
        })
      const receiverFeeTx = await receiverFeePromise
      const receiverFeeReceipt = await receiverFeeTx.wait()
      expect(receiverFeePromise)
        .to.emit(contract, 'HasToPayFee')
        .withArgs(transactionId, TransactionParty.Sender)
      const [
        receiverFeeTransactionId,
        receiverFeeTransaction
      ] = getEmittedEvent('TransactionStateUpdated', receiverFeeReceipt).args

      await increaseTime(feeTimeout / 2)
      await expect(
        contract
          .connect(other)
          .timeOutByReceiver(receiverFeeTransactionId, receiverFeeTransaction)
      ).to.be.revertedWith('Timeout time has not passed yet.')
    })
  })

  describe('Evidence', () => {
    it('Should allow sender and receiver to submit evidence', async () => {
      const [
        receipt,
        transactionId,
        transaction
      ] = await createTransactionHelper(amount)
      await submitEvidenceHelper(
        transactionId,
        transaction,
        'ipfs:/evidence_001',
        sender
      )
      await submitEvidenceHelper(
        transactionId,
        transaction,
        'ipfs:/evidence_002',
        receiver
      )
      await submitEvidenceHelper(
        transactionId,
        transaction,
        'ipfs:/evidence_003',
        other
      ) // Not allowed

      const [
        disputeID,
        disputeTransactionId,
        disputeTransaction
      ] = await createDisputeHelper(transactionId, transaction)
      await submitEvidenceHelper(
        disputeTransactionId,
        disputeTransaction,
        'ipfs:/evidence_004',
        sender
      )
      await submitEvidenceHelper(
        disputeTransactionId,
        disputeTransaction,
        'ipfs:/evidence_005',
        receiver
      )

      await giveFinalRulingHelper(disputeID, DisputeRuling.Sender)
      const [ruleTransactionId, ruleTransaction] = await executeRulingHelper(
        disputeTransactionId,
        disputeTransaction,
        other
      )
      await submitEvidenceHelper(
        ruleTransactionId,
        ruleTransaction,
        'ipfs:/evidence_006',
        sender
      ) // Not allowed
      await submitEvidenceHelper(
        ruleTransactionId,
        ruleTransaction,
        'ipfs:/evidence_007',
        receiver
      ) // Not allowed
    })
  })

  describe('Multiple transactions', () => {
    it('Should handle multiple transactions concurrently', async () => {
      const amount_2 = amount + 500
      const [
        receipt_1,
        transactionId_1,
        transaction_1
      ] = await createTransactionHelper(amount)
      const [
        receipt_2,
        transactionId_2,
        transaction_2
      ] = await createTransactionHelper(amount_2)

      const [
        disputeID_1,
        disputeTransactionId_1,
        disputeTransaction_1
      ] = await createDisputeHelper(transactionId_1, transaction_1)
      const [
        disputeID_2,
        disputeTransactionId_2,
        disputeTransaction_2
      ] = await createDisputeHelper(transactionId_2, transaction_2)
      await submitEvidenceHelper(
        disputeTransactionId_1,
        disputeTransaction_1,
        'ipfs:/evidence_1_001',
        sender
      )
      await submitEvidenceHelper(
        disputeTransactionId_2,
        disputeTransaction_2,
        'ipfs:/evidence_2_001',
        receiver
      )

      await giveFinalRulingHelper(disputeID_1, DisputeRuling.Sender)
      await giveFinalRulingHelper(disputeID_2, DisputeRuling.Receiver)

      const balancesBefore = await getBalances()
      await executeRulingHelper(
        disputeTransactionId_1,
        disputeTransaction_1,
        other
      )
      await executeRulingHelper(
        disputeTransactionId_2,
        disputeTransaction_2,
        other
      )
      const balancesAfter = await getBalances()

      expect(
        balancesBefore.sender.add(BigNumber.from(arbitrationFee + amount))
      ).to.equal(balancesAfter.sender, 'Wrong sender balance.')
      expect(
        balancesBefore.receiver.add(BigNumber.from(arbitrationFee + amount_2))
      ).to.equal(balancesAfter.receiver, 'Wrong receiver balance.')
    })
  })

  describe('Appeals', () => {
    it('Should revert funding of appeals when the right conditions are not met', async () => {
      const [
        receipt,
        transactionId,
        transaction
      ] = await createTransactionHelper(amount)
      await expect(
        contract
          .connect(crowdfunder1)
          .fundAppeal(transactionId, transaction, TransactionParty.None, {
            value: 100
          })
      ).to.be.revertedWith('Wrong party.')
      await expect(
        contract
          .connect(crowdfunder1)
          .fundAppeal(transactionId, transaction, TransactionParty.Sender, {
            value: 100
          })
      ).to.be.revertedWith('No dispute to appeal')

      const [
        disputeID,
        disputeTransactionId,
        disputeTransaction
      ] = await createDisputeHelper(transactionId, transaction)
      await expect(
        contract
          .connect(crowdfunder1)
          .fundAppeal(
            disputeTransactionId,
            disputeTransaction,
            TransactionParty.Sender,
            { value: 100 }
          )
      ).to.be.revertedWith('Dispute is not appealable.')

      // Rule against the receiver
      await giveRulingHelper(disputeID, DisputeRuling.Sender)

      await increaseTime(appealTimeout / 2 + 1)
      await expect(
        contract
          .connect(crowdfunder1)
          .fundAppeal(
            disputeTransactionId,
            disputeTransaction,
            TransactionParty.Receiver,
            { value: 100 }
          )
      ).to.be.revertedWith(
        'The loser must pay during the first half of the appeal period.'
      )

      await increaseTime(appealTimeout / 2 + 1)
      await expect(
        contract
          .connect(crowdfunder1)
          .fundAppeal(
            disputeTransactionId,
            disputeTransaction,
            TransactionParty.Sender,
            { value: 100 }
          )
      ).to.be.revertedWith('Funding must be made within the appeal period.')
    })

    it('Should handle appeal fees correctly while emitting the correct events', async () => {
      const loserAppealFee =
        arbitrationFee + (arbitrationFee * loserMultiplier) / MULTIPLIER_DIVISOR
      const winnerAppealFee =
        arbitrationFee +
        (arbitrationFee * winnerMultiplier) / MULTIPLIER_DIVISOR
      let paidFees
      let hasPaid
      let feeRewards

      const [
        receipt,
        transactionId,
        transaction
      ] = await createTransactionHelper(amount)
      const [
        disputeID,
        disputeTransactionId,
        disputeTransaction
      ] = await createDisputeHelper(transactionId, transaction)

      // Round zero must be created but empty
      ;[paidFees, hasPaid, feeRewards] = await contract.getRoundInfo(
        transactionId,
        0
      )
      expect(paidFees[TransactionParty.None].toNumber()).to.be.equal(
        0,
        'Wrong paidFee for party None'
      )
      expect(paidFees[TransactionParty.Sender].toNumber()).to.be.equal(
        0,
        'Wrong paidFee for party Sender'
      )
      expect(paidFees[TransactionParty.Receiver].toNumber()).to.be.equal(
        0,
        'Wrong paidFee for party Receiver'
      )
      expect(hasPaid[TransactionParty.None]).to.be.equal(
        false,
        'Wrong hasPaid for party None'
      )
      expect(hasPaid[TransactionParty.Sender]).to.be.equal(
        false,
        'Wrong hasPaid for party Sender'
      )
      expect(hasPaid[TransactionParty.Receiver]).to.be.equal(
        false,
        'Wrong hasPaid for party Receiver'
      )
      expect(feeRewards.toNumber()).to.be.equal(0, 'Wrong feeRewards')

      await giveRulingHelper(disputeID, DisputeRuling.Sender)

      // Fully fund the loser side
      const txPromise1 = contract
        .connect(crowdfunder1)
        .fundAppeal(
          transactionId,
          disputeTransaction,
          TransactionParty.Receiver,
          { value: loserAppealFee }
        )
      const tx1 = await txPromise1
      const receipt1 = await tx1.wait()
      expect(txPromise1)
        .to.emit(contract, 'AppealFeeContribution')
        .withArgs(
          transactionId,
          TransactionParty.Receiver,
          await crowdfunder1.getAddress(),
          loserAppealFee
        )
      expect(txPromise1)
        .to.emit(contract, 'HasPaidAppealFee')
        .withArgs(transactionId, TransactionParty.Receiver)

      // Fully fund the winner side
      const txPromise2 = contract
        .connect(crowdfunder2)
        .fundAppeal(
          transactionId,
          disputeTransaction,
          TransactionParty.Sender,
          {
            value: winnerAppealFee
          }
        )
      const tx2 = await txPromise2
      const receipt2 = await tx2.wait()
      expect(txPromise2)
        .to.emit(contract, 'AppealFeeContribution')
        .withArgs(
          transactionId,
          TransactionParty.Sender,
          await crowdfunder2.getAddress(),
          winnerAppealFee
        )
      expect(txPromise2)
        .to.emit(contract, 'HasPaidAppealFee')
        .withArgs(transactionId, TransactionParty.Sender)

      // Round zero must be updated correctly
      ;[paidFees, hasPaid, feeRewards] = await contract.getRoundInfo(
        transactionId,
        0
      )
      expect(paidFees[TransactionParty.None].toNumber()).to.be.equal(
        0,
        'Wrong paidFee for party None'
      )
      expect(paidFees[TransactionParty.Sender].toNumber()).to.be.equal(
        winnerAppealFee,
        'Wrong paidFee for party Sender'
      )
      expect(paidFees[TransactionParty.Receiver].toNumber()).to.be.equal(
        loserAppealFee,
        'Wrong paidFee for party Receiver'
      )
      expect(hasPaid[TransactionParty.None]).to.be.equal(
        false,
        'Wrong hasPaid for party None'
      )
      expect(hasPaid[TransactionParty.Sender]).to.be.equal(
        true,
        'Wrong hasPaid for party Sender'
      )
      expect(hasPaid[TransactionParty.Receiver]).to.be.equal(
        true,
        'Wrong hasPaid for party Receiver'
      )
      expect(feeRewards.toNumber()).to.be.equal(
        winnerAppealFee + loserAppealFee - arbitrationFee,
        'Wrong feeRewards'
      )

      // Round one must be created but empty
      ;[paidFees, hasPaid, feeRewards] = await contract.getRoundInfo(
        transactionId,
        1
      )
      expect(paidFees[TransactionParty.None].toNumber()).to.be.equal(
        0,
        'Wrong paidFee for party None'
      )
      expect(paidFees[TransactionParty.Sender].toNumber()).to.be.equal(
        0,
        'Wrong paidFee for party Sender'
      )
      expect(paidFees[TransactionParty.Receiver].toNumber()).to.be.equal(
        0,
        'Wrong paidFee for party Receiver'
      )
      expect(hasPaid[TransactionParty.None]).to.be.equal(
        false,
        'Wrong hasPaid for party None'
      )
      expect(hasPaid[TransactionParty.Sender]).to.be.equal(
        false,
        'Wrong hasPaid for party Sender'
      )
      expect(hasPaid[TransactionParty.Receiver]).to.be.equal(
        false,
        'Wrong hasPaid for party Receiver'
      )
      expect(feeRewards.toNumber()).to.be.equal(0, 'Wrong feeRewards')
    })

    it('Should handle appeal fees correctly while emitting the correct events (2)', async () => {
      const loserAppealFee =
        arbitrationFee + (arbitrationFee * loserMultiplier) / MULTIPLIER_DIVISOR
      const winnerAppealFee =
        arbitrationFee +
        (arbitrationFee * winnerMultiplier) / MULTIPLIER_DIVISOR
      const gasPrice = 1000000000
      let paidFees
      let hasPaid
      let feeRewards

      const [
        receipt,
        transactionId,
        transaction
      ] = await createTransactionHelper(amount)
      const [
        disputeID,
        disputeTransactionId,
        disputeTransaction
      ] = await createDisputeHelper(transactionId, transaction)
      await giveRulingHelper(disputeID, DisputeRuling.Sender)

      // CROWDFUND THE RECEIVER SIDE
      // Partially fund the loser side
      const contribution1 = loserAppealFee / 2
      const txPromise1 = contract
        .connect(crowdfunder1)
        .fundAppeal(
          transactionId,
          disputeTransaction,
          TransactionParty.Receiver,
          {
            value: contribution1
          }
        )
      const tx1 = await txPromise1
      const receipt1 = await tx1.wait()
      expect(txPromise1)
        .to.emit(contract, 'AppealFeeContribution')
        .withArgs(
          transactionId,
          TransactionParty.Receiver,
          await crowdfunder1.getAddress(),
          contribution1
        )
      // Round zero must be updated correctly
      ;[paidFees, hasPaid, feeRewards] = await contract.getRoundInfo(
        transactionId,
        0
      )
      expect(paidFees[TransactionParty.None].toNumber()).to.be.equal(
        0,
        'Wrong paidFee for party None'
      )
      expect(paidFees[TransactionParty.Sender].toNumber()).to.be.equal(
        0,
        'Wrong paidFee for party Sender'
      )
      expect(paidFees[TransactionParty.Receiver].toNumber()).to.be.equal(
        contribution1,
        'Wrong paidFee for party Receiver'
      )
      expect(hasPaid[TransactionParty.None]).to.be.equal(
        false,
        'Wrong hasPaid for party None'
      )
      expect(hasPaid[TransactionParty.Sender]).to.be.equal(
        false,
        'Wrong hasPaid for party Sender'
      )
      expect(hasPaid[TransactionParty.Receiver]).to.be.equal(
        false,
        'Wrong hasPaid for party Receiver'
      )
      expect(feeRewards.toNumber()).to.be.equal(0, 'Wrong feeRewards')

      // Overpay fee and check if contributor is refunded
      const balanceBeforeContribution2 = await receiver.getBalance()
      const expectedContribution2 = loserAppealFee - contribution1
      const txPromise2 = contract
        .connect(receiver)
        .fundAppeal(
          transactionId,
          disputeTransaction,
          TransactionParty.Receiver,
          {
            value: loserAppealFee,
            gasPrice: gasPrice
          }
        )
      const tx2 = await txPromise2
      const receipt2 = await tx2.wait()
      expect(txPromise2)
        .to.emit(contract, 'AppealFeeContribution')
        .withArgs(
          transactionId,
          TransactionParty.Receiver,
          receiverAddress,
          expectedContribution2
        )
      expect(txPromise2)
        .to.emit(contract, 'HasPaidAppealFee')
        .withArgs(transactionId, TransactionParty.Receiver)
      // Contributor must be refunded correctly
      const balanceAfterContribution2 = await receiver.getBalance()
      expect(balanceBeforeContribution2).to.equal(
        balanceAfterContribution2
          .add(BigNumber.from(expectedContribution2))
          .add(receipt2.gasUsed * gasPrice),
        'Contributor was not refunded correctly'
      )
      // Round zero must be updated correctly
      ;[paidFees, hasPaid, feeRewards] = await contract.getRoundInfo(
        transactionId,
        0
      )
      expect(paidFees[TransactionParty.None].toNumber()).to.be.equal(
        0,
        'Wrong paidFee for party None'
      )
      expect(paidFees[TransactionParty.Sender].toNumber()).to.be.equal(
        0,
        'Wrong paidFee for party Sender'
      )
      expect(paidFees[TransactionParty.Receiver].toNumber()).to.be.equal(
        loserAppealFee,
        'Wrong paidFee for party Receiver'
      )
      expect(hasPaid[TransactionParty.None]).to.be.equal(
        false,
        'Wrong hasPaid for party None'
      )
      expect(hasPaid[TransactionParty.Sender]).to.be.equal(
        false,
        'Wrong hasPaid for party Sender'
      )
      expect(hasPaid[TransactionParty.Receiver]).to.be.equal(
        true,
        'Wrong hasPaid for party Receiver'
      )
      expect(feeRewards.toNumber()).to.be.equal(
        loserAppealFee,
        'Wrong feeRewards'
      )
      // The side is fully funded and new contributions must be reverted
      await expect(
        contract
          .connect(crowdfunder1)
          .fundAppeal(
            transactionId,
            disputeTransaction,
            TransactionParty.Receiver,
            { value: loserAppealFee }
          )
      ).to.be.revertedWith('Appeal fee has already been paid.')

      // CROWDFUND THE SENDER SIDE
      // Partially fund the winner side
      const contribution3 = winnerAppealFee / 2
      const txPromise3 = contract
        .connect(crowdfunder2)
        .fundAppeal(
          transactionId,
          disputeTransaction,
          TransactionParty.Sender,
          {
            value: contribution3
          }
        )
      const tx3 = await txPromise3
      const receipt3 = await tx3.wait()
      expect(txPromise3)
        .to.emit(contract, 'AppealFeeContribution')
        .withArgs(
          transactionId,
          TransactionParty.Sender,
          await crowdfunder2.getAddress(),
          contribution3
        )
      // Round zero must be updated correctly
      ;[paidFees, hasPaid, feeRewards] = await contract.getRoundInfo(
        transactionId,
        0
      )
      expect(paidFees[TransactionParty.None].toNumber()).to.be.equal(
        0,
        'Wrong paidFee for party None'
      )
      expect(paidFees[TransactionParty.Sender].toNumber()).to.be.equal(
        contribution3,
        'Wrong paidFee for party Sender'
      )
      expect(paidFees[TransactionParty.Receiver].toNumber()).to.be.equal(
        loserAppealFee,
        'Wrong paidFee for party Receiver'
      )
      expect(hasPaid[TransactionParty.None]).to.be.equal(
        false,
        'Wrong hasPaid for party None'
      )
      expect(hasPaid[TransactionParty.Sender]).to.be.equal(
        false,
        'Wrong hasPaid for party Sender'
      )
      expect(hasPaid[TransactionParty.Receiver]).to.be.equal(
        true,
        'Wrong hasPaid for party Receiver'
      )
      expect(feeRewards.toNumber()).to.be.equal(
        loserAppealFee,
        'Wrong feeRewards'
      )

      // Overpay fee and check if contributor is refunded
      const balanceBeforeContribution4 = await sender.getBalance()
      const expectedContribution4 = winnerAppealFee - contribution3
      const txPromise4 = contract
        .connect(sender)
        .fundAppeal(
          transactionId,
          disputeTransaction,
          TransactionParty.Sender,
          {
            value: winnerAppealFee,
            gasPrice: gasPrice
          }
        )
      const tx4 = await txPromise4
      const receipt4 = await tx4.wait()
      expect(txPromise4)
        .to.emit(contract, 'AppealFeeContribution')
        .withArgs(
          transactionId,
          TransactionParty.Sender,
          senderAddress,
          expectedContribution4
        )
      expect(txPromise4)
        .to.emit(contract, 'HasPaidAppealFee')
        .withArgs(transactionId, TransactionParty.Sender)
      // Contributor must be refunded correctly
      const balanceAfterContribution4 = await sender.getBalance()
      expect(balanceBeforeContribution4).to.equal(
        balanceAfterContribution4
          .add(BigNumber.from(expectedContribution4))
          .add(receipt4.gasUsed * gasPrice),
        'Contributor was not refunded correctly'
      )
      // Round zero must be updated correctly
      ;[paidFees, hasPaid, feeRewards] = await contract.getRoundInfo(
        transactionId,
        0
      )
      expect(paidFees[TransactionParty.None].toNumber()).to.be.equal(
        0,
        'Wrong paidFee for party None'
      )
      expect(paidFees[TransactionParty.Sender].toNumber()).to.be.equal(
        winnerAppealFee,
        'Wrong paidFee for party Sender'
      )
      expect(paidFees[TransactionParty.Receiver].toNumber()).to.be.equal(
        loserAppealFee,
        'Wrong paidFee for party Receiver'
      )
      expect(hasPaid[TransactionParty.None]).to.be.equal(
        false,
        'Wrong hasPaid for party None'
      )
      expect(hasPaid[TransactionParty.Sender]).to.be.equal(
        true,
        'Wrong hasPaid for party Sender'
      )
      expect(hasPaid[TransactionParty.Receiver]).to.be.equal(
        true,
        'Wrong hasPaid for party Receiver'
      )
      expect(feeRewards.toNumber()).to.be.equal(
        loserAppealFee + winnerAppealFee - arbitrationFee,
        'Wrong feeRewards'
      )
    })

    it('Should change the ruling if loser paid appeal fee while winner did not', async () => {
      const loserAppealFee =
        arbitrationFee + (arbitrationFee * loserMultiplier) / MULTIPLIER_DIVISOR

      const [
        receipt,
        transactionId,
        transaction
      ] = await createTransactionHelper(amount)
      const [
        disputeID,
        disputeTransactionId,
        disputeTransaction
      ] = await createDisputeHelper(transactionId, transaction)
      await giveRulingHelper(disputeID, DisputeRuling.Receiver)

      // Fully fund the loser side
      const tx1 = await contract
        .connect(crowdfunder1)
        .fundAppeal(
          transactionId,
          disputeTransaction,
          TransactionParty.Sender,
          { value: loserAppealFee }
        )
      const receipt1 = await tx1.wait()

      // Give final ruling and expect it to change
      await increaseTime(appealTimeout + 1)
      const [txPromise2, tx2, receipt2] = await giveRulingHelper(
        disputeID,
        DisputeRuling.Receiver
      )
      expect(txPromise2)
        .to.emit(contract, 'Ruling')
        .withArgs(arbitrator.address, disputeID, TransactionParty.Sender)
    })
  })

  describe('Withdrawals', () => {
    it('Should withdraw correct fees if dispute had winner/loser', async () => {
      const loserAppealFee =
        arbitrationFee + (arbitrationFee * loserMultiplier) / MULTIPLIER_DIVISOR
      const winnerAppealFee =
        arbitrationFee +
        (arbitrationFee * winnerMultiplier) / MULTIPLIER_DIVISOR
      let paidFees
      let hasPaid
      let feeRewards

      const [
        receipt,
        transactionId,
        transaction
      ] = await createTransactionHelper(amount)
      const [
        disputeID,
        disputeTransactionId,
        disputeTransaction
      ] = await createDisputeHelper(transactionId, transaction)
      await giveRulingHelper(disputeID, DisputeRuling.Sender)

      // Crowdfund the receiver side
      const contribution1 = loserAppealFee / 2
      await fundAppealHelper(
        transactionId,
        disputeTransaction,
        crowdfunder1,
        contribution1,
        TransactionParty.Receiver
      )

      const contribution2 = loserAppealFee - contribution1
      await fundAppealHelper(
        transactionId,
        disputeTransaction,
        receiver,
        contribution2,
        TransactionParty.Receiver
      )

      // Withdraw must be reverted at this point.
      await expect(
        contract
          .connect(crowdfunder1)
          .withdrawFeesAndRewards(
            await crowdfunder1.getAddress(),
            transactionId,
            disputeTransaction,
            0
          )
      ).to.be.revertedWith('The transaction must be resolved.')
      await expect(
        contract
          .connect(crowdfunder1)
          .batchRoundWithdraw(
            await crowdfunder1.getAddress(),
            transactionId,
            disputeTransaction,
            0,
            0
          )
      ).to.be.revertedWith('The transaction must be resolved.')

      // Crowdfund the sender side (crowdfunder1 funds both sides)
      const contribution3 = winnerAppealFee / 2
      await fundAppealHelper(
        transactionId,
        disputeTransaction,
        crowdfunder1,
        contribution3,
        TransactionParty.Sender
      )

      const contribution4 = winnerAppealFee - contribution3
      await fundAppealHelper(
        transactionId,
        disputeTransaction,
        crowdfunder2,
        contribution4 / 2,
        TransactionParty.Sender
      )
      await fundAppealHelper(
        transactionId,
        disputeTransaction,
        crowdfunder2,
        contribution4 / 2,
        TransactionParty.Sender
      )

      // Give and execute final ruling, then withdraw
      const appealDisputeID = await arbitrator.getAppealDisputeID(disputeID)
      await giveFinalRulingHelper(
        appealDisputeID,
        DisputeRuling.Sender,
        disputeID
      )
      const [ruleTransactionId, ruleTransaction] = await executeRulingHelper(
        disputeTransactionId,
        disputeTransaction,
        other
      )

      const balancesBefore = await getBalances()
      await withdrawHelper(
        await crowdfunder1.getAddress(),
        transactionId,
        ruleTransaction,
        0,
        other
      )
      await withdrawHelper(
        await crowdfunder1.getAddress(),
        transactionId,
        ruleTransaction,
        0,
        other
      ) // Attempt to withdraw twice
      await withdrawHelper(
        await crowdfunder2.getAddress(),
        transactionId,
        ruleTransaction,
        0,
        other
      )
      await withdrawHelper(
        senderAddress,
        transactionId,
        ruleTransaction,
        0,
        other
      )
      await withdrawHelper(
        receiverAddress,
        transactionId,
        ruleTransaction,
        0,
        other
      )
      const balancesAfter = await getBalances()

      expect(balancesBefore.receiver).to.equal(
        balancesBefore.receiver,
        'Contributors of the loser side must not be rewarded'
      )
      expect(balancesAfter.sender).to.equal(
        balancesAfter.sender,
        'Non contributors must not be rewarded'
      )
      ;[paidFees, hasPaid, feeRewards] = await contract.getRoundInfo(
        transactionId,
        0
      )
      const reward3 = BigNumber.from(contribution3)
        .mul(feeRewards)
        .div(paidFees[TransactionParty.Sender])
      expect(balancesBefore.crowdfunder1.add(reward3)).to.equal(
        balancesAfter.crowdfunder1,
        'Contributor 1 was not rewarded correctly'
      )

      const reward4 = BigNumber.from(contribution4)
        .mul(feeRewards)
        .div(paidFees[TransactionParty.Sender])
      expect(balancesBefore.crowdfunder2.add(reward4)).to.equal(
        balancesAfter.crowdfunder2,
        'Contributor 2 was not rewarded correctly'
      )
    })

    it("Should withdraw correct fees if arbitrator refused to arbitrate'", async () => {
      const loserAppealFee =
        arbitrationFee + (arbitrationFee * loserMultiplier) / MULTIPLIER_DIVISOR
      const winnerAppealFee =
        arbitrationFee +
        (arbitrationFee * winnerMultiplier) / MULTIPLIER_DIVISOR
      let paidFees
      let hasPaid
      let feeRewards

      const [
        receipt,
        transactionId,
        transaction
      ] = await createTransactionHelper(amount)
      const [
        disputeID,
        disputeTransactionId,
        disputeTransaction
      ] = await createDisputeHelper(transactionId, transaction)
      await giveRulingHelper(disputeID, DisputeRuling.Sender)

      // Crowdfund the receiver side
      const contribution1 = loserAppealFee / 2
      await fundAppealHelper(
        transactionId,
        disputeTransaction,
        crowdfunder1,
        contribution1,
        TransactionParty.Receiver
      )

      const contribution2 = loserAppealFee - contribution1
      await fundAppealHelper(
        transactionId,
        disputeTransaction,
        receiver,
        contribution2,
        TransactionParty.Receiver
      )

      // Crowdfund the sender side (crowdfunder1 funds both sides)
      const contribution3 = winnerAppealFee / 2
      await fundAppealHelper(
        transactionId,
        disputeTransaction,
        crowdfunder1,
        contribution3,
        TransactionParty.Sender
      )

      const contribution4 = winnerAppealFee - contribution3
      await fundAppealHelper(
        transactionId,
        disputeTransaction,
        crowdfunder2,
        contribution4 / 2,
        TransactionParty.Sender
      )
      await fundAppealHelper(
        transactionId,
        disputeTransaction,
        crowdfunder2,
        contribution4 / 2,
        TransactionParty.Sender
      )

      // Give and execute final ruling, then withdraw
      const appealDisputeID = await arbitrator.getAppealDisputeID(disputeID)
      await giveFinalRulingHelper(
        appealDisputeID,
        DisputeRuling.RefusedToRule,
        disputeID
      )
      const [ruleTransactionId, ruleTransaction] = await executeRulingHelper(
        disputeTransactionId,
        disputeTransaction,
        other
      )

      const balancesBefore = await getBalances()
      await withdrawHelper(
        await crowdfunder1.getAddress(),
        transactionId,
        ruleTransaction,
        0,
        other
      )
      await withdrawHelper(
        await crowdfunder1.getAddress(),
        transactionId,
        ruleTransaction,
        0,
        other
      ) // Attempt to withdraw twice
      await withdrawHelper(
        await crowdfunder2.getAddress(),
        transactionId,
        ruleTransaction,
        0,
        other
      )
      await withdrawHelper(
        senderAddress,
        transactionId,
        ruleTransaction,
        0,
        other
      )
      await withdrawHelper(
        receiverAddress,
        transactionId,
        ruleTransaction,
        0,
        other
      )
      const balancesAfter = await getBalances()

      expect(balancesBefore.sender).to.equal(
        balancesAfter.sender,
        'Non contributors must not be rewarded'
      )
      ;[paidFees, hasPaid, feeRewards] = await contract.getRoundInfo(
        transactionId,
        0
      )
      const totalFeesPaid = paidFees[TransactionParty.Sender].add(
        paidFees[TransactionParty.Receiver]
      )

      const reward2 = BigNumber.from(contribution2)
        .mul(feeRewards)
        .div(totalFeesPaid)
      expect(balancesBefore.receiver.add(reward2)).to.equal(
        balancesAfter.receiver,
        'Contributor was not rewarded correctly (2)'
      )

      const reward3 = BigNumber.from(contribution1 + contribution3)
        .mul(feeRewards)
        .div(totalFeesPaid)
      expect(balancesBefore.crowdfunder1.add(reward3)).to.equal(
        balancesAfter.crowdfunder1,
        'Contributor was not rewarded correctly (3)'
      )

      const reward4 = BigNumber.from(contribution4)
        .mul(feeRewards)
        .div(totalFeesPaid)
      expect(balancesBefore.crowdfunder2.add(reward4)).to.equal(
        balancesAfter.crowdfunder2,
        'Contributor was not rewarded correctly (4)'
      )
    })

    it("Should allow many rounds and batch-withdraw the fees after the final ruling'", async () => {
      const loserAppealFee =
        arbitrationFee + (arbitrationFee * loserMultiplier) / MULTIPLIER_DIVISOR
      const winnerAppealFee =
        arbitrationFee +
        (arbitrationFee * winnerMultiplier) / MULTIPLIER_DIVISOR
      const roundsLength = 4
      const winnerSide = TransactionParty.Sender

      const [
        receipt,
        transactionId,
        transaction
      ] = await createTransactionHelper(amount)
      const [
        disputeID,
        disputeTransactionId,
        disputeTransaction
      ] = await createDisputeHelper(transactionId, transaction)

      let roundDisputeID
      roundDisputeID = disputeID
      for (var round_i = 0; round_i < roundsLength; round_i += 1) {
        await giveRulingHelper(roundDisputeID, DisputeRuling.Sender)
        // Fully fund both sides
        await fundAppealHelper(
          transactionId,
          disputeTransaction,
          crowdfunder1,
          loserAppealFee,
          TransactionParty.Receiver
        )
        await fundAppealHelper(
          transactionId,
          disputeTransaction,
          crowdfunder2,
          winnerAppealFee,
          winnerSide
        )
        roundDisputeID = await arbitrator.getAppealDisputeID(disputeID)
      }

      // Give and execute final ruling
      await giveFinalRulingHelper(
        roundDisputeID,
        DisputeRuling.Sender,
        disputeID
      )
      const [ruleTransactionId, ruleTransaction] = await executeRulingHelper(
        disputeTransactionId,
        disputeTransaction,
        other
      )

      // Batch-withdraw (checking if _cursor and _count arguments are working as expected).
      const balancesBefore = await getBalances()
      const amountWithdrawable1 = await contract.amountWithdrawable(
        transactionId,
        ruleTransaction,
        await crowdfunder1.getAddress()
      )
      const amountWithdrawable2 = await contract.amountWithdrawable(
        transactionId,
        ruleTransaction,
        await crowdfunder2.getAddress()
      )

      const tx1 = await contract
        .connect(other)
        .batchRoundWithdraw(
          await crowdfunder1.getAddress(),
          transactionId,
          ruleTransaction,
          0,
          0
        )
      await tx1.wait()
      const tx2 = await contract
        .connect(other)
        .batchRoundWithdraw(
          await crowdfunder2.getAddress(),
          transactionId,
          ruleTransaction,
          0,
          2
        )
      await tx2.wait()
      const tx3 = await contract
        .connect(other)
        .batchRoundWithdraw(
          await crowdfunder2.getAddress(),
          transactionId,
          ruleTransaction,
          0,
          10
        )
      await tx3.wait()

      const balancesAfter = await getBalances()

      expect(amountWithdrawable1).to.equal(
        BigNumber.from(0),
        'Wrong amount withdrawable'
      )
      expect(balancesBefore.crowdfunder1).to.equal(
        balancesAfter.crowdfunder1,
        'Losers must not be rewarded.'
      )

      // In this case all rounds have equal fees and rewards to simplify calculations
      const [paidFees, hasPaid, feeRewards] = await contract.getRoundInfo(
        transactionId,
        0
      )

      const roundReward = BigNumber.from(winnerAppealFee)
        .mul(feeRewards)
        .div(paidFees[winnerSide])
      const totalReward = roundReward.mul(BigNumber.from(roundsLength))

      expect(balancesBefore.crowdfunder2.add(totalReward)).to.equal(
        balancesAfter.crowdfunder2,
        'Contributor was not rewarded correctly'
      )

      expect(amountWithdrawable2).to.equal(
        BigNumber.from(totalReward),
        'Wrong withdrawable amount'
      )
    })
  })

  async function createTransactionHelper(_amount) {
    const metaEvidence = metaEvidenceUri

    const tx = await contract
      .connect(sender)
      .createTransaction(timeoutPayment, receiverAddress, metaEvidence, {
        value: _amount
      })
    const receipt = await tx.wait()
    const [transactionId, transaction] = getEmittedEvent(
      'TransactionStateUpdated',
      receipt
    ).args

    return [receipt, transactionId, transaction]
  }

  async function createDisputeHelper(
    _transactionId,
    _transaction,
    fee = arbitrationFee
  ) {
    // Pay fees, create dispute and validate events.
    const receiverTxPromise = contract
      .connect(receiver)
      .payArbitrationFeeByReceiver(_transactionId, _transaction, {
        value: fee
      })
    const receiverFeeTx = await receiverTxPromise
    const receiverFeeReceipt = await receiverFeeTx.wait()
    expect(receiverTxPromise)
      .to.emit(contract, 'HasToPayFee')
      .withArgs(_transactionId, TransactionParty.Sender)
    const [receiverFeeTransactionId, receiverFeeTransaction] = getEmittedEvent(
      'TransactionStateUpdated',
      receiverFeeReceipt
    ).args
    const txPromise = contract
      .connect(sender)
      .payArbitrationFeeBySender(
        receiverFeeTransactionId,
        receiverFeeTransaction,
        {
          value: fee
        }
      )
    const senderFeeTx = await txPromise
    const senderFeeReceipt = await senderFeeTx.wait()
    const [senderFeeTransactionId, senderFeeTransaction] = getEmittedEvent(
      'TransactionStateUpdated',
      senderFeeReceipt
    ).args
    expect(txPromise)
      .to.emit(contract, 'Dispute')
      .withArgs(
        arbitrator.address,
        senderFeeTransaction.disputeID,
        senderFeeTransactionId,
        senderFeeTransactionId
      )
    expect(senderFeeTransaction.status).to.equal(
      TransactionStatus.DisputeCreated,
      'Invalid transaction status'
    )
    return [
      senderFeeTransaction.disputeID,
      senderFeeTransactionId,
      senderFeeTransaction
    ]
  }

  async function submitEvidenceHelper(
    transactionId,
    transaction,
    evidence,
    caller
  ) {
    const callerAddress = await caller.getAddress()
    if (
      callerAddress == transaction.sender ||
      callerAddress == transaction.receiver
    ) {
      if (transaction.status != TransactionStatus.Resolved) {
        const txPromise = contract
          .connect(caller)
          .submitEvidence(transactionId, transaction, evidence)
        const tx = await txPromise
        const receipt = await tx.wait()
        expect(txPromise)
          .to.emit(contract, 'Evidence')
          .withArgs(arbitrator.address, transactionId, callerAddress, evidence)
      } else {
        await expect(
          contract
            .connect(caller)
            .submitEvidence(transactionId, transaction, evidence)
        ).to.be.revertedWith(
          'Must not send evidence if the dispute is resolved.'
        )
      }
    } else {
      await expect(
        contract
          .connect(caller)
          .submitEvidence(transactionId, transaction, evidence)
      ).to.be.revertedWith('The caller must be the sender or the receiver.')
    }
  }

  async function giveRulingHelper(disputeID, ruling) {
    // Notice that rule() function is not called by the arbitrator, because the dispute is appealable.
    const txPromise = arbitrator.giveRuling(disputeID, ruling)
    const tx = await txPromise
    const receipt = await tx.wait()

    return [txPromise, tx, receipt]
  }

  async function giveFinalRulingHelper(
    disputeID,
    ruling,
    transactionDisputeId = disputeID
  ) {
    const firstTx = await arbitrator.giveRuling(disputeID, ruling)
    await firstTx.wait()

    await increaseTime(appealTimeout + 1)

    const txPromise = arbitrator.giveRuling(disputeID, ruling)
    const tx = await txPromise
    const receipt = await tx.wait()

    expect(txPromise)
      .to.emit(contract, 'Ruling')
      .withArgs(arbitrator.address, transactionDisputeId, ruling)

    return [txPromise, tx, receipt]
  }

  async function executeRulingHelper(transactionId, transaction, caller) {
    const tx = await contract
      .connect(caller)
      .executeRuling(transactionId, transaction)
    const receipt = await tx.wait()
    const [newTransactionId, newTransaction] = getEmittedEvent(
      'TransactionStateUpdated',
      receipt
    ).args

    return [newTransactionId, newTransaction]
  }

  async function fundAppealHelper(
    transactionId,
    transaction,
    caller,
    contribution,
    side
  ) {
    const txPromise = contract
      .connect(caller)
      .fundAppeal(transactionId, transaction, side, { value: contribution })
    const tx = await txPromise
    const receipt = await tx.wait()

    return [txPromise, tx, receipt]
  }

  async function withdrawHelper(
    beneficiary,
    transactionId,
    transaction,
    round,
    caller
  ) {
    const txPromise = contract
      .connect(caller)
      .withdrawFeesAndRewards(beneficiary, transactionId, transaction, round)
    const tx = await txPromise
    const receipt = await tx.wait()

    return [txPromise, tx, receipt]
  }

  async function getBalances() {
    const balances = {
      sender: await sender.getBalance(),
      receiver: await receiver.getBalance(),
      contract: await web3.eth.getBalance(contract.address),
      crowdfunder1: await crowdfunder1.getBalance(),
      crowdfunder2: await crowdfunder2.getBalance()
    }
    return balances
  }
})