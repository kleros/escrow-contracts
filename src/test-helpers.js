const { time } = require('@openzeppelin/test-helpers')

function randomInt(max) {
  return Math.ceil(Math.random() * max)
}

function getEmittedEvent(eventName, receipt) {
  return receipt.events.find(({ event }) => event === eventName)
}

async function latestTime() {
  return Number(await time.latest())
}

async function increaseTime(secondsPassed) {
  return time.increase(secondsPassed)
}

module.exports = {
  randomInt,
  getEmittedEvent,
  latestTime,
  increaseTime
}
