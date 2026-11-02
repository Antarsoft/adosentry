from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth import CurrentUser, get_current_user, hash_password
from app.db import get_session
from app.models import AuditEvent, User

router = APIRouter(prefix="/users", tags=["users"])


async def record_event(session: AsyncSession, kind: str, user_id: int) -> None:
    session.add(AuditEvent(kind=kind, user_id=user_id))
    await session.commit()


class UserUpdate(BaseModel):
    display_name: str | None = None
    email: str | None = None
    role: str | None = None
    password: str | None = None


@router.patch("/me")
async def update_me(
    payload: UserUpdate,
    current: CurrentUser = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    user = await session.get(User, current.id)
    if user is None:
        raise HTTPException(status_code=404)
    changes = payload.model_dump(exclude_unset=True)
    if "password" in changes:
        user.hashed_password = hash_password(changes.pop("password"))
    for field, value in changes.items():
        setattr(user, field, value)
    await session.commit()
    record_event(session, "user.updated", user.id)
    return user
