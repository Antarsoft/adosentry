using Shop.Api.Data;
using Shop.Api.Endpoints;
using Shop.Api.Services;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddDbContext<ShopDbContext>();
builder.Services.AddSingleton<PriceCache>();
builder.Services.AddControllers();
builder.Services.AddAuthentication().AddJwtBearer();
builder.Services.AddAuthorization();

var app = builder.Build();
app.UseAuthentication();
app.UseAuthorization();
app.MapControllers();
app.MapOrderEndpoints();
app.Run();
