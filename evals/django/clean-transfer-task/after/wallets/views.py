from decimal import Decimal

from django.contrib.auth.decorators import login_required
from django.db import transaction
from django.http import JsonResponse
from django.views.decorators.http import require_POST

from .forms import TransferForm
from .models import Wallet
from .tasks import send_transfer_receipt


@login_required
@require_POST
def transfer(request, wallet_id):
    form = TransferForm(request.POST)
    if not form.is_valid():
        return JsonResponse({"errors": form.errors}, status=400)

    amount: Decimal = form.cleaned_data["amount"]
    target_id = form.cleaned_data["target_id"]
    if target_id == wallet_id:
        return JsonResponse({"error": "Choose a different wallet."}, status=400)

    with transaction.atomic():
        # Lock both rows in primary-key order so opposite transfers cannot deadlock.
        # Payments can go to any wallet; only the source must belong to the caller.
        locked = {w.pk: w for w in Wallet.objects.select_for_update().filter(pk__in=[wallet_id, target_id]).order_by("pk")}
        source = locked.get(wallet_id)
        target = locked.get(target_id)
        if source is None or target is None or source.owner_id != request.user.id:
            return JsonResponse({"error": "Wallet not found."}, status=404)
        if source.balance < amount:
            return JsonResponse({"error": "Insufficient balance."}, status=409)
        source.balance -= amount
        target.balance += amount
        source.save(update_fields=["balance"])
        target.save(update_fields=["balance"])
        transaction.on_commit(lambda: send_transfer_receipt.delay(source.pk, target.pk, str(amount)))

    return JsonResponse({"balance": str(source.balance)})
