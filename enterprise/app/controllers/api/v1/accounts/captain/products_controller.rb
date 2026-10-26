class Api::V1::Accounts::Captain::ProductsController < Api::V1::Accounts::BaseController
  before_action -> { check_authorization(Captain::Product) }
  before_action :set_assistant
  before_action :set_product, only: [:show, :update, :destroy]

  def index
    @products = assistant_products.order(:name)
    @products = @products.where('name ILIKE ?', "%#{Captain::Product.sanitize_sql_like(params[:searchKey])}%") if params[:searchKey].present?
  end

  def show; end

  def create
    @product = assistant_products.create!(product_params.merge(account: Current.account))
  end

  def update
    @product.update!(product_params)
  end

  def destroy
    @product.destroy
    head :no_content
  end

  private

  def set_assistant
    @assistant = Current.account.captain_assistants.find(params[:assistant_id])
  end

  def set_product
    @product = assistant_products.find(params[:id])
  end

  def assistant_products
    @assistant.products
  end

  def product_params
    params.require(:product).permit(:name, :description, :prompt, :context, :shopee_item_id, :enabled, :confirmed)
  end
end
