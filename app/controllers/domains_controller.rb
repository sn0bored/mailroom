class DomainsController < ApplicationController
  before_action :set_domain, only: %i[show update probe]

  def index
    @domains = Domain.order(:name)
  end

  def new
    @domain = Domain.new
  end

  def create
    @domain = Domain.new(domain_params)
    if @domain.save
      redirect_to @domain, notice: "Domain added."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def show
    @messages = @domain.messages.newest_first.limit(10)
    @message_count = @domain.messages.count
    @forwarded_count = @domain.messages.where(forward_status: "sent").count
    @skipped_counts = @domain.messages.where("forward_status LIKE ?", "skipped:%").group(:forward_status).count
    @probe = OutboundMessage.where(kind: "probe").newest_first.detect { |record| record.to_addresses.include?(@domain.probe_address) }
  end

  def update
    if @domain.update(domain_params)
      redirect_to @domain, notice: "Domain updated."
    else
      show
      render :show, status: :unprocessable_entity
    end
  end

  def probe
    Outbound::Probe.call(@domain, actor: Current.user)
    redirect_to @domain, notice: "Probe queued."
  rescue Outbound::Send::NotAllowed, NotImplementedError => error
    redirect_to @domain, alert: error.message.presence || "Probe sending is not available yet."
  end

  private

  def set_domain
    @domain = Domain.find(params[:id])
  end

  def domain_params
    attributes = params.require(:domain).permit(:name, :forward_copy_to, :send_enabled,
      :forward_copy_max_spam, :notes, :forward_mode, :forward_addresses)
    if attributes.key?(:forward_addresses)
      attributes[:forward_addresses] = attributes[:forward_addresses].to_s.lines.map { |line| line.strip.downcase }.reject(&:blank?).uniq
    end
    attributes
  end
end
