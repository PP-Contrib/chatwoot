# Mostly modeled after the intial implementation of the service based on 360 Dialog
# https://docs.360dialog.com/whatsapp-api/whatsapp-api/media
# https://developers.facebook.com/docs/whatsapp/api/media/
class Whatsapp::IncomingMessageBaseService
  include ::Whatsapp::IncomingMessageServiceHelpers

  pattr_initialize [:inbox!, :params!]

  def perform
    processed_params

    if processed_params[:statuses].present?
      process_statuses
    elsif processed_params[:messages].present?
      process_messages
    end
  end

  private

  def find_message_by_source_id(source_id)
    return unless source_id

    @message = Message.find_by(source_id: source_id)
  end

  def process_messages
    # message allready exists so we don't need to process
    return if find_message_by_source_id(@processed_params[:messages].first[:id])

    set_contact
    return unless @contact

    set_conversation
    set_message_type
    create_messages
  end

  def process_statuses
    return unless find_message_by_source_id(@processed_params[:statuses].first[:id])

    update_message_with_status(@message, @processed_params[:statuses].first)
  rescue ArgumentError => e
    Rails.logger.error "Error while processing whatsapp status update #{e.message}"
  end

  def update_message_with_status(message, state)
    ActiveRecord::Base.transaction do
      create_message_for_failed_status(message, state)

      if state[:status] == 'deleted'
        message.assign_attributes(content: I18n.t('conversations.messages.deleted'), content_attributes: { deleted: true })
      else
        message.status = state[:status]
      end
      message.save!
    end
  end

  def create_message_for_failed_status(message, state)
    return if state[:status] != 'failed' || state[:errors]&.empty?

    error = state[:errors]&.first
    message.external_error = "#{error[:code]}: #{error[:title]}"
    Message.create!(
      conversation_id: message.conversation_id, content: "#{error[:code]}: #{error[:title]}",
      account_id: @inbox.account_id, inbox_id: @inbox.id, message_type: :activity, sender: message.sender, source_id: message.source_id
    )
  end

  def create_messages
    return if unprocessable_message_type?(message_type)
    message = @processed_params[:messages].first
    if message_type == 'contacts'
      create_contact_messages(message)
    else
      create_regular_message(message)
    end
  end

  def create_contact_messages(message)
    message['contacts'].each do |contact|
      create_message(contact)
      attach_contact(contact)
      @message.save!
    end
  end

  def create_regular_message(message)
    create_message(message)
    attach_files
    attach_location if message_type == 'location'
    @message.save!
  end

  def set_contact
    contact_params = @processed_params[:contacts]&.first
    return if contact_params.blank?

    contact_inbox = ::ContactInboxWithContactBuilder.new(
      source_id: contact_params[:wa_id],
      inbox: inbox,
      contact_attributes: { name: contact_params.dig(:profile, :name), phone_number: "+#{@processed_params[:messages].first[:from]}" }
    ).perform

    @contact_inbox = contact_inbox
    @contact = contact_inbox.contact
    @sender = contact_inbox.contact
  end

  def set_conversation
    @conversation = @contact_inbox.conversations.last || ::Conversation.create!(conversation_params)
  end

  def attach_files
    return if %w[text button interactive location contacts].include?(message_type)

    attachment_payload = @processed_params[:messages].first[message_type.to_sym]
    @message.content ||= attachment_payload[:caption]

    attachment_file = download_attachment_file(attachment_payload)
    return if attachment_file.blank?

    @message.attachments.new(
      account_id: @message.account_id, file_type: file_content_type(message_type), file: {
        io: attachment_file, filename: attachment_file.original_filename, content_type: attachment_file.content_type
      }
    )
  end

  def attach_location
    location = @processed_params[:messages].first['location']
    location_name = location['name'] ? "#{location['name']}, #{location['address']}" : ''
    @message.attachments.new(
      account_id: @message.account_id, file_type: file_content_type(message_type), coordinates_lat: location['latitude'],
      coordinates_long: location['longitude'], fallback_title: location_name, external_url: location['url']
    )
  end

  def create_message(message)
    @message = @conversation.messages.build(
      content: message_content(message),
      account_id: @inbox.account_id,
      inbox_id: @inbox.id,
      message_type: @message_type,
      sender: @sender,
      source_id: message[:id].to_s
    )
  end

  def attach_contact(contact)
    phones = contact[:phones]
    phones = [{ phone: 'Phone number is not available' }] if phones.blank?

    phones.each do |phone|
      @message.attachments.new(
        account_id: @message.account_id,
        file_type: file_content_type(message_type),
        fallback_title: phone[:phone].to_s
      )
    end
  end

  def set_message_type
    @message_type = :incoming
  end
end
