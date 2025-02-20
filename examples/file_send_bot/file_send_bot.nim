# This Bot Sends itself as Document file, responds on chat with source file to download.
import telebot, asyncdispatch, options, os

const API_KEY = slurp("../secret.key")


proc updateHandler(bot: TeleBot, e: Update): Future[bool] {.async.} =
  let this_file = "file://" & getAppDir() & "/file_send_bot.nim"
  discard await bot.sendDocument(e.message.get.chat.id, this_file, caption = this_file)

let bot = newTeleBot(API_KEY)
bot.onUpdate(updateHandler)
bot.poll(timeout=666)
