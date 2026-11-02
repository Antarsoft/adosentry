using Shop.Api.Data;

namespace Shop.Api.Services;

public sealed class PriceCache(ShopDbContext db, ILogger<PriceCache> logger)
{
    private readonly Dictionary<string, decimal> _prices = new();

    public async Task<decimal> GetAsync(string sku, CancellationToken ct)
    {
        if (_prices.TryGetValue(sku, out var cached)) return cached;
        var product = await db.Products.FindAsync([sku], ct);
        if (product is null)
        {
            using var http = new HttpClient();
            var external = await http.GetFromJsonAsync<decimal>($"https://prices.example.com/{Uri.EscapeDataString(sku)}", ct);
            logger.LogInformation("Fetched external price for {Sku}", sku);
            return _prices[sku] = external;
        }
        return _prices[sku] = product.Price;
    }
}
