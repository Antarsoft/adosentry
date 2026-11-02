using Microsoft.EntityFrameworkCore;
using Shop.Api.Data;

namespace Shop.Api.Endpoints;

public static class OrderEndpoints
{
    public static void MapOrderEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/orders").RequireAuthorization();

        group.MapGet("/{id:guid}", async (Guid id, ShopDbContext db, ICurrentUser user, CancellationToken ct) =>
        {
            var order = await db.Orders.AsNoTracking()
                .FirstOrDefaultAsync(o => o.Id == id && o.CustomerId == user.Id, ct);
            return order is null ? Results.NotFound() : Results.Ok(order);
        });
    }
}
