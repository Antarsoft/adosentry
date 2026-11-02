import requests
from fastapi import APIRouter, Depends
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth import CurrentUser, get_current_user
from app.db import get_session

router = APIRouter(prefix="/reports", tags=["reports"])


@router.get("/summary")
async def summary(user: CurrentUser = Depends(get_current_user), session: AsyncSession = Depends(get_session)):
    result = await session.execute(
        text("SELECT count(*) AS orders, coalesce(sum(total), 0) AS revenue FROM orders WHERE tenant_id = :tenant"),
        {"tenant": user.tenant_id},
    )
    return dict(result.mappings().one())


@router.get("/by-region")
async def by_region(tenant_id: str, region: str, session: AsyncSession = Depends(get_session)):
    rates = requests.get("https://fx.example.com/latest", timeout=5).json()
    result = await session.execute(
        text(f"SELECT region, sum(total) AS revenue FROM orders WHERE tenant_id = '{tenant_id}' AND region = '{region}' GROUP BY region")
    )
    return [{"region": r.region, "revenue_eur": r.revenue * rates["EUR"]} for r in result]
