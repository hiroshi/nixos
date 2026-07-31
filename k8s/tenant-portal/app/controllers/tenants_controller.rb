class TenantsController < ApplicationController
  before_action :set_tenant, only: %i[show destroy code]

  def index
    reap_deleted_tenants
    @tenants = Tenant.order(:name)
    @phases = @tenants.to_h { |tenant| [ tenant.id, tenant.agent.status["phase"] ] }
  end

  def new
    @tenant = Tenant.new
  end

  # Provisioning is a handful of kubectl calls, fast enough to do inline; the
  # slow part (image pull, OAuth) happens in the pod and is polled by #show.
  def create
    @tenant = Tenant.new(tenant_params.merge(status: "provisioning"))
    return render :new, status: :unprocessable_entity unless @tenant.save

    begin
      @tenant.provisioner.provision!
      @tenant.update!(status: "active", last_error: nil)
      redirect_to @tenant, notice: "#{@tenant.namespace} を作成しました。"
    rescue TenantProvisioner::Error => e
      @tenant.update!(status: "failed", last_error: e.message)
      redirect_to @tenant, alert: "作成に失敗しました。"
    end
  end

  def show
    @status = @tenant.agent.status
  end

  def code
    ok, message = @tenant.agent.submit_code(params[:code].to_s.strip)
    if ok
      redirect_to @tenant, notice: "code を送信しました。認証を待っています…"
    else
      redirect_to @tenant, alert: message
    end
  end

  def destroy
    @tenant.provisioner.destroy!
    @tenant.update!(status: "deleting")
    redirect_to tenants_path, notice: "#{@tenant.namespace} を削除しています。"
  rescue TenantProvisioner::Error => e
    @tenant.update!(status: "failed", last_error: e.message)
    redirect_to tenants_path, alert: "削除に失敗しました。"
  end

  private

  def set_tenant
    @tenant = Tenant.find(params[:id])
  end

  def tenant_params
    params.expect(tenant: [ :name ])
  end

  # Namespace termination is asynchronous, so a deleted tenant's row sticks
  # around until its namespace is actually gone.
  def reap_deleted_tenants
    Tenant.where(status: "deleting").each do |tenant|
      tenant.destroy! unless tenant.provisioner.namespace_exists?
    rescue TenantProvisioner::Error => e
      Rails.logger.warn("could not check #{tenant.namespace}: #{e.message}")
    end
  end
end
