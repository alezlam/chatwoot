json.payload do
  json.array! @products do |product|
    json.partial! 'api/v1/models/captain/product', product: product
  end
end

json.meta do
  json.total_count @products.size
end
