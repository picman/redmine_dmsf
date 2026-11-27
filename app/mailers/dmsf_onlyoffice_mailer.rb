# frozen_string_literal: true

class DmsfOnlyofficeMailer < Mailer
  def mention(recipient, author, file, message, link)
    return unless DmsfOnlyofficeSession.allowed_mode?(file: file, user: recipient, mode: 'view')

    @author = author
    @file = file
    @message = message
    @link = link
    mail to: recipient.mail, subject: "[#{file.project.name}] #{file.title}: #{author.name}"
  end
end
