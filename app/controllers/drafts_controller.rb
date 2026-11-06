class DraftsController < ApplicationController
  before_action :set_draft, only: %i[show update deliver]

  def index
    @drafts = OutboundMessage.drafts.newest_first
  end

  def show
  end

  def new
    @draft = build_draft
  end

  def create
    @draft = build_draft
    @draft.assign_attributes(draft_params.merge(status: "draft", user: Current.user))
    if @draft.save
      redirect_to draft_path(@draft), notice: "Draft saved."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def update
    return redirect_to draft_path(@draft), alert: "Only drafts can be edited." unless @draft.draft?
    if @draft.update(draft_params.merge(status: "draft", user: Current.user))
      redirect_to draft_path(@draft), notice: "Draft saved."
    else
      render :show, status: :unprocessable_entity
    end
  end

  def deliver
    return redirect_to draft_path(@draft), alert: "Only drafts can be sent." unless @draft.draft?
    Outbound::Send.call(@draft, actor: Current.user)
    redirect_to draft_path(@draft), notice: "Message queued for sending."
  rescue Outbound::Send::NotAllowed, NotImplementedError => error
    redirect_to draft_path(@draft), alert: error.message.presence || "Sending is not available yet."
  end

  private

  def set_draft
    @draft = OutboundMessage.find(params[:id])
  end

  def build_draft
    draft = OutboundMessage.new(kind: "api", status: "draft")
    if params[:message_id].present?
      source = Message.find(params[:message_id])
      draft.assign_attributes(kind: "reply", source_message: source, from_address: source.to_address,
        to_addresses: [ source.reply_to.presence || source.from_address ],
        subject: source.subject.to_s.match?(/\ARe:/i) ? source.subject : "Re: #{source.subject}",
        in_reply_to: source.rfc822_message_id,
        references_header: [ source.references_header, source.rfc822_message_id ].compact.join(" "),
        text_body: "\n" + source.body_text.to_s.split("\n", -1).map { |line| "> #{line}" }.join("\n"))
    end
    draft
  end

  def draft_params
    attributes = params.require(:draft).permit(:from_address, :subject, :text_body, :to)
    attributes[:to_addresses] = attributes.delete(:to).to_s.split(",").map(&:strip).reject(&:blank?)
    attributes
  end
end
