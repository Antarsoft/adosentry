using Microsoft.EntityFrameworkCore;
using Shop.Api.Data;

namespace Shop.Api.Endpoints;

public static class InvoiceEndpoints
{
    public sealed record InvoiceSummary(Guid Id, string Number, decimal Total, DateOnly IssuedOn);

    public static void MapInvoiceEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/invoices").RequireAuthorization();

        group.MapGet("/", async (ShopDbContext db, ICurrentUser user, CancellationToken ct, int page = 1, int pageSize = 25) =>
        {
            page = Math.Max(page, 1);
            pageSize = Math.Clamp(pageSize, 1, 100);

            var items = await db.Invoices
                .AsNoTracking()
                .Where(i => i.CustomerId == user.Id)
                .OrderByDescending(i => i.IssuedOn)
                .Skip((page - 1) * pageSize)
                .Take(pageSize)
                .Select(i => new InvoiceSummary(i.Id, i.Number, i.Total, i.IssuedOn))
                .ToListAsync(ct);

            return Results.Ok(items);
        });
    }
}
