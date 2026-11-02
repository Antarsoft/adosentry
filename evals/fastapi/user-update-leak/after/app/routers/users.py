from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession

from app.audit import record_event
from app.auth import CurrentUser, get_current_user
from app.db import get_session
from app.models import User

router = APIRouter(prefix="/users", tags=["users"])


class UserUpdate(BaseModel):
    display_name: str | None = None
    email: str | None = None
    role: str | None = None


@router.patch("/me")
async def update_me(
    payload: UserUpdate,
    current: CurrentUser = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    user = await session.get(User, current.id)
    if user is None:
        raise HTTPException(status_code=404)
    for field, value in payload.model_dump(exclude_unset=True).items():
        setattr(user, field, value)
    await session.commit()
    record_event(session, "user.updated", user.id)
    return user
