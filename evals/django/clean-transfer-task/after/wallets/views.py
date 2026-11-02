from decimal import Decimal

from django.contrib.auth.decorators import login_required
from django.db import transaction
from django.http import JsonResponse
from django.shortcuts import get_object_or_404
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
    with transaction.atomic():
        source = get_object_or_404(Wallet.objects.select_for_update(), pk=wallet_id, owner=request.user)
        target = get_object_or_404(Wallet.objects.select_for_update(), pk=form.cleaned_data["target_id"])
        if source.balance < amount:
            return JsonResponse({"error": "Insufficient balance."}, status=409)
        source.balance -= amount
        target.balance += amount
        source.save(update_fields=["balance"])
        target.save(update_fields=["balance"])
        transaction.on_commit(lambda: send_transfer_receipt.delay(source.pk, target.pk, str(amount)))

    return JsonResponse({"balance": str(source.balance)})
