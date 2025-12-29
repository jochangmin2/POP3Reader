package com.xcurenet.pop3reader.service;

import com.xcurenet.pop3reader.model.MailData;
import org.jsoup.Jsoup;
import org.springframework.stereotype.Service;

import javax.mail.Message;
import javax.mail.Part;
import javax.mail.internet.MimeMultipart;

@Service
public class MailParserService {

	public MailData parse(Message msg, final String mailPop3Username) throws Exception {
		return MailData.builder().accountId(mailPop3Username).messageId(getMessageId(msg)).from(msg.getFrom() != null ? msg.getFrom()[0].toString() : "").subject(msg.getSubject()).sentDate(msg.getSentDate()).body(Jsoup.parse(extractText(msg)).wholeText()).msg(msg).build();
	}

	private String extractText(Part part) throws Exception {
		if (part.isMimeType("text/*")) {
			return part.getContent().toString();
		}
		if (part.isMimeType("multipart/*")) {
			MimeMultipart mp = (MimeMultipart) part.getContent();
			for (int i = 0; i < mp.getCount(); i++) {
				Part bp = mp.getBodyPart(i);
				if (bp.isMimeType("text/plain")) {
					return bp.getContent().toString();
				}
			}
		}
		return "";
	}

	private String getMessageId(Message msg) {
		try {
			String[] h = msg.getHeader("Message-ID");
			return (h != null && h.length > 0) ? h[0] : null;
		} catch (Exception e) {
			return null;
		}
	}
}
