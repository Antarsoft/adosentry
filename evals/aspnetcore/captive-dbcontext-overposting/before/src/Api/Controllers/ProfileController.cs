using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;
using Shop.Api.Data;

namespace Shop.Api.Controllers;

[ApiController]
[Authorize]
[Route("profile")]
public sealed class ProfileController(ShopDbContext db, ICurrentUser user) : ControllerBase
{
    [HttpGet]
    public async Task<IActionResult> Get(CancellationToken ct)
    {
        var customer = await db.Customers.AsNoTracking().SingleAsync(c => c.Id == user.Id, ct);
        return Ok(new { customer.Id, customer.DisplayName, customer.Email });
    }
}
