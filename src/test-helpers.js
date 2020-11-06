const { time } = require('@openzeppelin/test-helpers')

/**
 * Get randomInt
 * @param {number} max Max integer.
 * @returns {number} Random integer in the range (0, max].
 */
function randomInt(max) {
  return Math.ceil(Math.random() * max)
}

/**
 * getEmittedEvent
 * @param {string} eventName Name of the expected event.
 * @param {Promise} receipt Transaction promise.
 * @returns {object} Event data.
 */
function getEmittedEvent(eventName, receipt) {
  return receipt.events.find(({ event }) => event === eventName)
}

/**
 * Get latest time
 * @returns {number} Latest time.
 */
async function latestTime() {
  return Number(await time.latest())
}

/**
 * Increase time by secondsPassed seconds.
 * @param {number} secondsPassed Time delta in seconds.
 * @returns {number} New current time.
 */
async function increaseTime(secondsPassed) {
  return time.increase(secondsPassed)
}

module.exports = {
  randomInt,
  getEmittedEvent,
  latestTime,
  increaseTime
}
