import { v4 as uuidv4 } from 'uuid'
import express from 'express'
import { createServer } from 'http'
import message from './message.js'
import bridge from './bridge.js'
import validate from './validate.js'
import { redisConnect, redisDisconnect, setConfig } from './redis.js'

const app = express()
app.use(express.json())
const server = createServer(app)

const port = process.env.PORT || 8888

const run = async (req, res) => {
  console.info('Received token: ', req.params.token, req.body)
  const token = req.params.token
  const config = { ...req.body, token }
  try {
    console.log(validate)
    await validate(config)
  } catch (error) {
    console.warn('Config is invalid', error)
    res.status(422).send(error)
    return false
  }
  try {
    await bridge(token, config)
    const redisClient = await redisConnect()
    await setConfig(redisClient, token, config)
    await redisDisconnect(redisClient, false)
    res.status(200).send('Success connected Chatwoot to WhatsApp')
  } catch (error) {
    res.status(400).send(error)
  }
}

/**
 * 
 * 
 * 
  {
    "baseURL": "http://localhost:3000"
    "token": "KLo3Lupshver3GFTks4eRBjh",
    "account_id": "2",
    "inbox_id": "3"
  }
 * 
 */
app.post('/connect', async (req, res) => {
  const token = uuidv4()
  console.info('Generated token: ', token)
  req.params.token = token
  run(req, res)
})

app.post('/connect/:token([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})', async (req, res) => {
  await run(req, res)
})

app.post('/message/:token([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})', message)

app.get('/ping', async (_req, res) => {
  res.send('pong!')
})

server.listen(port, () => {
  console.log(`Listening on *:${port}`)
})