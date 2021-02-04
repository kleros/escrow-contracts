const { ethers } = require('@nomiclabs/buidler')
const { readArtifact } = require('@nomiclabs/buidler/plugins')
const { solidity } = require('ethereum-waffle')
const { use, expect } = require('chai')

const { getEmittedEvent, increaseTime } = require('../src/test-helpers')
const TransactionParty = require('../src/entities/transaction-party')
const DisputeRuling = require('../src/entities/dispute-ruling')

use(solidity)

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
  const metaEvidenceUri = 'https://kleros.io'

  let arbitrator
  let _governor
  let sender
  let receiver
  let other
  let crowdfunder1
  let crowdfunder2

  let contract
  let MULTIPLIER_DIVISOR

  let contractArtifact

  beforeEach('Setup contracts', async () => {
    ;[
      _governor,
      sender,
      receiver,
      other,
      crowdfunder1,
      crowdfunder2
    ] = await ethers.getSigners()

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

    contractArtifact = await readArtifact(
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

    // The first transaction is more expensive, because the hashes array is empty. Skip it to estimate gas costs on normal conditions.
    await createTransactionHelper(amount)

    MULTIPLIER_DIVISOR = await contract.MULTIPLIER_DIVISOR()
  })

  describe('Bytecode size estimations', () => {
    it('Should be smaller than the maximum allowed (24k)', async () => {
      const bytecode = contractArtifact.bytecode
      const deployed = contractArtifact.deployedBytecode
      const sizeOfB = bytecode.length / 2
      const sizeOfD = deployed.length / 2
      console.log('\tsize of bytecode in bytes = ', sizeOfB)
      console.log('\tsize of deployed in bytes = ', sizeOfD)
      expect(sizeOfD).to.be.lessThan(24576)
    })
  })

  describe('Gas costs estimations for single calls', () => {
    it('Estimate gas cost when creating transaction.', async () => {
      const receiverAddress = await receiver.getAddress()
      const metaEvidence = metaEvidenceUri

      const tx = await contract
        .connect(sender)
        .createTransaction(timeoutPayment, receiverAddress, metaEvidence, {
          value: amount
        })
      const receipt = await tx.wait()

      console.log('')
      console.log(
        '\tGas used by createTransaction():  ' + parseInt(receipt.gasUsed)
      )
    })

    it('Estimate gas cost when reimbursing the sender.', async () => {
      const [_receipt, transactionId] = await createTransactionHelper(amount)

      const reimburseTx = await contract
        .connect(receiver)
        .reimburse(transactionId, amount)
      const reimburseReceipt = await reimburseTx.wait()

      console.log('')
      console.log(
        '\tGas used by reimburse():  ' + parseInt(reimburseReceipt.gasUsed)
      )
    })

    it('Estimate gas cost when paying the receiver.', async () => {
      const [_receipt, transactionId] = await createTransactionHelper(amount)

      const payTx = await contract.connect(sender).pay(transactionId, amount)
      const payReceipt = await payTx.wait()

      console.log('')
      console.log('\tGas used by pay():  ' + parseInt(payReceipt.gasUsed))
    })

    it('Estimate gas cost when executing the a transaction.', async () => {
      const [_receipt, transactionId] = await createTransactionHelper(amount)

      await increaseTime(timeoutPayment)

      // Anyone should be allowed to execute the transaction.
      const executeTx = await contract
        .connect(other)
        .executeTransaction(transactionId)
      const executeReceipt = await executeTx.wait()

      console.log('')
      console.log(
        '\tGas used by executeTransaction():  ' +
          parseInt(executeReceipt.gasUsed)
      )
    })

    it('Estimate gas cost when paying fee (first party calling).', async () => {
      const [_receipt, transactionId] = await createTransactionHelper(amount)

      const senderFeePromise = contract
        .connect(sender)
        .payArbitrationFeeBySender(transactionId, {
          value: arbitrationFee
        })
      const senderFeeTx = await senderFeePromise
      const senderFeeReceipt = await senderFeeTx.wait()

      console.log('')
      console.log(
        '\tGas used by payArbitrationFeeBySender():  ' +
          parseInt(senderFeeReceipt.gasUsed)
      )
    })

    it('Estimate gas cost when paying fee (second party calling) and creating dispute.', async () => {
      const [_receipt, transactionId] = await createTransactionHelper(amount)

      const receiverTxPromise = contract
        .connect(receiver)
        .payArbitrationFeeByReceiver(transactionId, {
          value: arbitrationFee
        })
      const receiverFeeTx = await receiverTxPromise
      const _receiverFeeReceipt = await receiverFeeTx.wait()

      const senderFeePromise = contract
        .connect(sender)
        .payArbitrationFeeBySender(transactionId, {
          value: arbitrationFee
        })
      const senderFeeTx = await senderFeePromise
      const senderFeeReceipt = await senderFeeTx.wait()

      console.log('')
      console.log(
        '\tGas used by payArbitrationFeeBySender():  ' +
          parseInt(senderFeeReceipt.gasUsed)
      )
    })

    it('Estimate gas cost when timing out.', async () => {
      const [_receipt, transactionId] = await createTransactionHelper(amount)

      const senderFeePromise = contract
        .connect(sender)
        .payArbitrationFeeBySender(transactionId, {
          value: arbitrationFee
        })
      const senderFeeTx = await senderFeePromise
      const _senderFeeReceipt = await senderFeeTx.wait()

      // feeTimeout for receiver passes and sender gets to claim amount and his fee.
      await increaseTime(feeTimeout + 1)
      // Anyone can execute the timeout
      const timeoutTx = await contract
        .connect(other)
        .timeOutBySender(transactionId)
      const timeoutReceipt = await timeoutTx.wait()

      console.log('')
      console.log(
        '\tGas used by timeOutBySender():  ' + parseInt(timeoutReceipt.gasUsed)
      )
    })

    it('Estimate gas cost when executing a ruled dispute.', async () => {
      const [_receipt, transactionId] = await createTransactionHelper(amount)
      const [disputeID] = await createDisputeHelper(transactionId)

      const firstTx = await arbitrator.giveRuling(
        disputeID,
        DisputeRuling.Sender
      )
      await firstTx.wait()

      await increaseTime(appealTimeout + 1)

      const txPromise = arbitrator.giveRuling(disputeID, DisputeRuling.Sender)
      const tx = await txPromise
      const receipt = await tx.wait()

      console.log('')
      console.log('\tGas used by rule():  ' + parseInt(receipt.gasUsed))
    })

    it('Estimate gas cost when submitting evidence.', async () => {
      const [_receipt, transactionId] = await createTransactionHelper(amount)

      const txPromise = contract
        .connect(sender)
        .submitEvidence(transactionId, 'ipfs:/evidence_001')
      const tx = await txPromise
      const receipt = await tx.wait()

      console.log('')
      console.log(
        '\tGas used by submitEvidence():  ' + parseInt(receipt.gasUsed)
      )
    })

    it('Estimate gas cost when appealing one side (full funding).', async () => {
      const loserAppealFee =
        arbitrationFee + (arbitrationFee * loserMultiplier) / MULTIPLIER_DIVISOR

      const [_receipt, transactionId] = await createTransactionHelper(amount)
      const [disputeID] = await createDisputeHelper(transactionId)

      await giveRulingHelper(disputeID, DisputeRuling.Sender)

      // Fully fund the loser side
      const txPromise = contract
        .connect(receiver)
        .fundAppeal(transactionId, TransactionParty.Receiver, {
          value: loserAppealFee
        })
      const tx = await txPromise
      const receipt = await tx.wait()

      console.log('')
      console.log('\tGas used by fundAppeal():  ' + parseInt(receipt.gasUsed))
    })

    it('Estimate gas cost when appealing one side (partial funding).', async () => {
      const loserAppealFee =
        arbitrationFee + (arbitrationFee * loserMultiplier) / MULTIPLIER_DIVISOR

      const [_receipt, transactionId] = await createTransactionHelper(amount)
      const [disputeID] = await createDisputeHelper(transactionId)

      await giveRulingHelper(disputeID, DisputeRuling.Sender)

      // Fully fund the loser side
      const txPromise = contract
        .connect(crowdfunder1)
        .fundAppeal(transactionId, TransactionParty.Receiver, {
          value: loserAppealFee / 2
        })
      const tx = await txPromise
      const receipt = await tx.wait()

      console.log('')
      console.log('\tGas used by fundAppeal():  ' + parseInt(receipt.gasUsed))
    })

    it('Estimate gas cost when appealing one side (full funding) and creating new round.', async () => {
      const loserAppealFee =
        arbitrationFee + (arbitrationFee * loserMultiplier) / MULTIPLIER_DIVISOR
      const winnerAppealFee =
        arbitrationFee +
        (arbitrationFee * winnerMultiplier) / MULTIPLIER_DIVISOR

      const [_receipt, transactionId] = await createTransactionHelper(amount)
      const [disputeID] = await createDisputeHelper(transactionId)

      await giveRulingHelper(disputeID, DisputeRuling.Sender)

      // Fully fund the loser side
      await fundAppealHelper(
        transactionId,
        receiver,
        loserAppealFee,
        TransactionParty.Receiver
      )
      const [_txPromise, _tx, receipt] = await fundAppealHelper(
        transactionId,
        sender,
        winnerAppealFee,
        TransactionParty.Sender
      )

      console.log('')
      console.log('\tGas used by fundAppeal():  ' + parseInt(receipt.gasUsed))
    })

    it('Estimate gas cost when withdrawing one round (winner side).', async () => {
      const loserAppealFee =
        arbitrationFee + (arbitrationFee * loserMultiplier) / MULTIPLIER_DIVISOR
      const winnerAppealFee =
        arbitrationFee +
        (arbitrationFee * winnerMultiplier) / MULTIPLIER_DIVISOR

      const [_receipt, transactionId] = await createTransactionHelper(amount)
      const [disputeID] = await createDisputeHelper(transactionId)

      await giveRulingHelper(disputeID, DisputeRuling.Sender)

      // Fully fund the loser side
      await fundAppealHelper(
        transactionId,
        receiver,
        loserAppealFee,
        TransactionParty.Receiver
      )
      await fundAppealHelper(
        transactionId,
        sender,
        winnerAppealFee,
        TransactionParty.Sender
      )

      // Give and execute final ruling
      const appealDisputeID = await arbitrator.getAppealDisputeID(disputeID)
      await giveFinalRulingHelper(
        appealDisputeID,
        DisputeRuling.Sender,
        disputeID
      )

      const [_txPromise, _tx, receipt] = await withdrawHelper(
        await sender.getAddress(),
        transactionId,
        0,
        sender
      )

      console.log('')
      console.log(
        '\tGas used by withdrawFeesAndRewards():  ' + parseInt(receipt.gasUsed)
      )
    })

    it('Estimate gas cost when batch-withdrawing 5 rounds (winner side).', async () => {
      const loserAppealFee =
        arbitrationFee + (arbitrationFee * loserMultiplier) / MULTIPLIER_DIVISOR
      const winnerAppealFee =
        arbitrationFee +
        (arbitrationFee * winnerMultiplier) / MULTIPLIER_DIVISOR
      const roundsLength = 5

      const [_receipt, transactionId] = await createTransactionHelper(amount)
      const [disputeID] = await createDisputeHelper(transactionId)

      let roundDisputeID
      roundDisputeID = disputeID
      for (var roundI = 0; roundI < roundsLength; roundI += 1) {
        await giveRulingHelper(roundDisputeID, DisputeRuling.Sender)
        // Fully fund both sides
        await fundAppealHelper(
          transactionId,
          crowdfunder1,
          loserAppealFee,
          TransactionParty.Receiver
        )
        await fundAppealHelper(
          transactionId,
          crowdfunder2,
          winnerAppealFee,
          TransactionParty.Sender
        )
        roundDisputeID = await arbitrator.getAppealDisputeID(disputeID)
      }

      // Give and execute final ruling
      await giveFinalRulingHelper(
        roundDisputeID,
        DisputeRuling.Sender,
        disputeID
      )

      // Batch-withdraw (checking if _cursor and _count arguments are working as expected).
      const txPromise = contract
        .connect(other)
        .batchRoundWithdraw(
          await crowdfunder2.getAddress(),
          transactionId,
          0,
          0
        )
      const tx = await txPromise
      const receipt = await tx.wait()

      console.log('')
      console.log(
        '\tGas used by batchRoundWithdraw():  ' + parseInt(receipt.gasUsed)
      )
    })
  })

  /**
   * Creates a transaction by sender to receiver.
   * @param {number} _amount Amount in wei.
   * @returns {Array} Tx data.
   */
  async function createTransactionHelper(_amount) {
    const receiverAddress = await receiver.getAddress()
    const metaEvidence = metaEvidenceUri

    const tx = await contract
      .connect(sender)
      .createTransaction(timeoutPayment, receiverAddress, metaEvidence, {
        value: _amount
      })
    const receipt = await tx.wait()
    const [transactionId, _buyer, _seller, _price] = getEmittedEvent(
      'TransactionCreated',
      receipt
    ).args

    return [receipt, transactionId]
  }

  /**
   * Make both sides pay arbitration fees. The transaction should have been previosuly created.
   * @param {number} _transactionId Id of the transaction.
   * @param {number} fee Appeal round from which to withdraw the rewards.
   * @returns {Array} Tx data.
   */
  async function createDisputeHelper(_transactionId, fee = arbitrationFee) {
    // Pay fees, create dispute and validate events.
    const receiverTxPromise = contract
      .connect(receiver)
      .payArbitrationFeeByReceiver(_transactionId, {
        value: fee
      })
    const receiverFeeTx = await receiverTxPromise
    const _receiverFeeReceipt = await receiverFeeTx.wait()
    expect(receiverTxPromise)
      .to.emit(contract, 'HasToPayFee')
      .withArgs(_transactionId, TransactionParty.Sender)

    const txPromise = contract
      .connect(sender)
      .payArbitrationFeeBySender(_transactionId, {
        value: fee
      })
    const senderFeeTx = await txPromise
    const senderFeeReceipt = await senderFeeTx.wait()
    const [_arbitrator, _disputeID, _a, _b] = getEmittedEvent(
      'Dispute',
      senderFeeReceipt
    ).args
    return [_disputeID]
  }

  /**
   * Give ruling (not final).
   * @param {number} disputeID dispute ID.
   * @param {number} ruling Ruling: None, Sender or Receiver.
   * @returns {Array} Tx data.
   */
  async function giveRulingHelper(disputeID, ruling) {
    // Notice that rule() function is not called by the arbitrator, because the dispute is appealable.
    const txPromise = arbitrator.giveRuling(disputeID, ruling)
    const tx = await txPromise
    const receipt = await tx.wait()

    return [txPromise, tx, receipt]
  }

  /**
   * Give final ruling and enforce it.
   * @param {number} disputeID dispute ID.
   * @param {number} ruling Ruling: None, Sender or Receiver.
   * @param {number} transactionDisputeId Initial dispute ID.
   * @returns {Array} Random integer in the range (0, max].
   */
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

  /**
   * Fund new appeal round.
   * @param {number} transactionId Id of the transaction.
   * @param {address} caller Can be anyone.
   * @param {number} contribution Contribution amount in wei.
   * @param {number} side Side to contribute to: Sender or Receiver.
   * @returns {Array} Tx data.
   */
  async function fundAppealHelper(transactionId, caller, contribution, side) {
    const txPromise = contract
      .connect(caller)
      .fundAppeal(transactionId, side, { value: contribution })
    const tx = await txPromise
    const receipt = await tx.wait()

    return [txPromise, tx, receipt]
  }

  /**
   * Withdraw rewards to beneficiary.
   * @param {address} beneficiary Address of the round contributor.
   * @param {number} transactionId Id of the transaction.
   * @param {number} round Appeal round from which to withdraw the rewards.
   * @param {address} caller Can be anyone.
   * @returns {Array} Tx data.
   */
  async function withdrawHelper(beneficiary, transactionId, round, caller) {
    const txPromise = contract
      .connect(caller)
      .withdrawFeesAndRewards(beneficiary, transactionId, round)
    const tx = await txPromise
    const receipt = await tx.wait()

    return [txPromise, tx, receipt]
  }
})
